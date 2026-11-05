"""Write one build-status badge per image workflow and Windows version, for the README's ltsc columns.

GitHub's own workflow badge is red if any Windows version fails, so it can't say which one. This reads the jobs of
each image workflow's recent runs on main and writes a shields.io endpoint file per version:

    <out>/<workflow stem>-<version>.json   e.g. go-container-2019.json

The README shows them with https://img.shields.io/endpoint?url=<raw URL of the file on the badges branch>.

Every run recomputes every image workflow, so a superseded run of the badges workflow loses nothing. A version
takes its status from the newest completed run where all of its legs finished (success or failure), so a cancelled
or skipped run doesn't blank the badge. A version an image doesn't build (ADR 0008 exceptions) gets no file.

    uv run python scripts/os_badges.py --out badges

It uses the authenticated `gh` CLI.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import Any

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = REPO_ROOT / ".github" / "workflows"
REUSABLE_WORKFLOW = "build-windows-image.yml"
# Also calls the reusable workflow, but rebuilds many images in one run; the badges follow each image's own workflow
REFRESH_WORKFLOW = "image-refresh.yml"
# Leg names from the reusable workflow end in the Windows version: "build / build-and-test (2019)"
LEG_VERSION = re.compile(r"\((20\d\d)\)$")
RUNS_TO_SCAN = 10
FINISHED = {"success", "failure", "timed_out", "startup_failure"}

Gh = Callable[[list[str]], str]


def gh(args: list[str]) -> str:
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=True).stdout


def image_workflows(workflows_dir: Path = WORKFLOWS_DIR) -> dict[str, str]:
    """{file name: workflow name} for every workflow with a job that calls the reusable image build."""
    found = {}
    for path in sorted(workflows_dir.glob("*.yml")):
        if path.name in {REUSABLE_WORKFLOW, REFRESH_WORKFLOW}:
            continue
        workflow = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        uses = [str(job.get("uses", "")) for job in (workflow.get("jobs") or {}).values()]
        if any(u.endswith(REUSABLE_WORKFLOW) for u in uses):
            found[path.name] = workflow["name"]
    return found


def version_status(jobs: Iterable[dict[str, Any]]) -> dict[str, str]:
    """{version: 'passing' | 'failing'} for each version whose legs in this run all finished."""
    legs: dict[str, list[str | None]] = {}
    for job in jobs:
        match = LEG_VERSION.search(job.get("name", ""))
        if match:
            legs.setdefault(match.group(1), []).append(job.get("conclusion"))
    status = {}
    for version, conclusions in legs.items():
        if any(c in FINISHED - {"success"} for c in conclusions):
            status[version] = "failing"
        elif all(c == "success" for c in conclusions):
            status[version] = "passing"
    return status


def latest_status(runs_jobs: Iterable[list[dict[str, Any]]]) -> dict[str, str]:
    """Per version, the status from the newest run that has one. `runs_jobs` is newest first, and is read only until
    every version seen so far has a status."""
    result: dict[str, str] = {}
    seen: set[str] = set()
    for jobs in runs_jobs:
        jobs = list(jobs)
        seen |= {m.group(1) for job in jobs if (m := LEG_VERSION.search(job.get("name", "")))}
        for version, status in version_status(jobs).items():
            result.setdefault(version, status)
        if seen and seen <= result.keys():
            break
    return result


def badge(version: str, status: str) -> dict[str, Any]:
    return {
        "schemaVersion": 1,
        "label": f"ltsc{version}",
        "message": status,
        "color": "brightgreen" if status == "passing" else "red",
    }


def runs_jobs(workflow: str, run_gh: Gh) -> Iterable[list[dict[str, Any]]]:
    """The jobs of the workflow's recent completed runs on main, newest first, fetched lazily."""
    listed = json.loads(
        run_gh(
            [
                "run",
                "list",
                "--workflow",
                workflow,
                "--branch",
                "main",
                "--status",
                "completed",
                "-L",
                str(RUNS_TO_SCAN),
                "--json",
                "databaseId,event",
            ]
        )
    )
    for run in listed:
        if run["event"] == "pull_request":
            continue
        yield json.loads(run_gh(["run", "view", str(run["databaseId"]), "--json", "jobs"]))["jobs"]


def main(argv: list[str] | None = None, run_gh: Gh = gh, workflows_dir: Path = WORKFLOWS_DIR) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, required=True, help="directory to write the badge files into")
    args = parser.parse_args(argv)
    args.out.mkdir(parents=True, exist_ok=True)
    for workflow in image_workflows(workflows_dir):
        stem = Path(workflow).stem
        for version, status in sorted(latest_status(runs_jobs(workflow, run_gh)).items()):
            path = args.out / f"{stem}-{version}.json"
            path.write_text(json.dumps(badge(version, status), indent=2) + "\n", encoding="utf-8")
            print(f"{path.name}: {status}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
