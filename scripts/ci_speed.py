"""Report how long CI image builds take before and after each milestone in ci/speed-milestones.json.

A milestone is a change meant to speed CI up, recorded with the commit that made it and when it was pushed. For every
build-and-test job leg (workflow, variant, Windows version) the report compares successful job durations:

- before: runs created before the milestone was pushed
- first after: the earliest run that contains the milestone commit. It usually starts with a cold cache.
- later: every later run that contains the milestone commit, which is what the change is meant to speed up

    uv run python scripts/ci_speed.py [--milestones ci/speed-milestones.json] [--runs 100] [--output report.md]

It reads the GitHub API with GH_TOKEN or GITHUB_TOKEN, or `gh auth token` when neither is set. Whether a run contains
the milestone is decided with `git merge-base --is-ancestor`, so run it in a clone with full history.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import urllib.request
from collections import defaultdict
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MILESTONES = REPO_ROOT / "ci" / "speed-milestones.json"
API = "https://api.github.com"
TIMEOUT_SECONDS = 30
JOB_MARKER = "build-and-test"
VERSION = re.compile(r"\b(2019|2022|2025)\b")


@dataclass(frozen=True)
class Milestone:
    id: str
    sha: str
    since: datetime
    description: str


@dataclass(frozen=True)
class JobSample:
    workflow: str
    leg: str  # e.g. "go1.26.10 2022" or "2025"
    head_sha: str
    run_created: datetime
    minutes: float


def parse_time(value: str) -> datetime:
    return datetime.fromisoformat(value)


def load_milestones(path: Path) -> list[Milestone]:
    return [
        Milestone(m["id"], m["sha"], parse_time(m["since"]), m["description"])
        for m in json.loads(path.read_text(encoding="utf-8"))
    ]


def leg_name(job_name: str) -> str | None:
    """'build (1.26.10) / build-and-test (2022)' -> 'go1.26.10 2022'; 'build / build-and-test (2025)' -> '2025'."""
    if JOB_MARKER not in job_name:
        return None
    version = VERSION.search(job_name.split(JOB_MARKER, 1)[1])
    if not version:
        return None
    variant = re.match(r"build \(([^)]+)\)", job_name)
    return f"go{variant.group(1)} {version.group(1)}" if variant else version.group(1)


def samples_from_runs(
    runs: Iterable[dict[str, Any]], jobs_of: Callable[[int], list[dict[str, Any]]]
) -> list[JobSample]:
    samples: list[JobSample] = []
    for run in runs:
        for job in jobs_of(run["id"]):
            leg = leg_name(job.get("name", ""))
            if (
                not leg
                or job.get("conclusion") != "success"
                or not job.get("started_at")
                or not job.get("completed_at")
            ):
                continue
            minutes = (parse_time(job["completed_at"]) - parse_time(job["started_at"])).total_seconds() / 60
            samples.append(JobSample(run["name"], leg, run["head_sha"], parse_time(run["created_at"]), minutes))
    return samples


@dataclass(frozen=True)
class LegReport:
    workflow: str
    leg: str
    before: list[float]
    first_after: float | None
    later: list[float]

    @property
    def speedup(self) -> float | None:
        if not self.before or not self.later:
            return None
        return statistics.median(self.before) / statistics.median(self.later)


def compare(samples: list[JobSample], milestone: Milestone, contains: Callable[[str, str], bool]) -> list[LegReport]:
    """Split each leg's samples into before, first run after, and later runs that contain the milestone."""
    grouped: dict[tuple[str, str], list[JobSample]] = defaultdict(list)
    for sample in samples:
        grouped[(sample.workflow, sample.leg)].append(sample)
    reports = []
    for (workflow, leg), leg_samples in sorted(grouped.items()):
        before = [s.minutes for s in leg_samples if s.run_created < milestone.since]
        after = sorted(
            (s for s in leg_samples if s.run_created >= milestone.since and contains(milestone.sha, s.head_sha)),
            key=lambda s: s.run_created,
        )
        reports.append(
            LegReport(workflow, leg, before, after[0].minutes if after else None, [s.minutes for s in after[1:]])
        )
    return reports


def _fmt(values: list[float]) -> str:
    return f"{statistics.median(values):.1f} min (n={len(values)})" if values else "-"


def markdown(milestone: Milestone, reports: list[LegReport], generated: datetime) -> str:
    lines = [
        f"## CI speed: {milestone.id}",
        "",
        f"Point of improvement: `{milestone.sha[:7]}`, pushed {milestone.since:%Y-%m-%d %H:%M} UTC. {milestone.description}.",
        "",
        "| Workflow | Leg | Before (median) | First run after | Later runs (median) | Speedup |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for r in reports:
        first = f"{r.first_after:.1f} min" if r.first_after is not None else "-"
        speedup = f"{r.speedup:.1f}x" if r.speedup is not None else "-"
        lines.append(f"| {r.workflow} | {r.leg} | {_fmt(r.before)} | {first} | {_fmt(r.later)} | {speedup} |")
    comparable = [r for r in reports if r.speedup is not None]
    lines.append("")
    if comparable:
        before_total = sum(statistics.median(r.before) for r in comparable)
        later_total = sum(statistics.median(r.later) for r in comparable)
        verdict = "faster" if later_total < before_total else "not faster"
        lines.append(
            f"**Overall ({len(comparable)} legs with data on both sides): {before_total:.0f} min before, "
            f"{later_total:.0f} min after, {before_total / later_total:.1f}x, {verdict}.**"
        )
    else:
        lines.append(
            "**No leg has a later run yet, so there is nothing to compare. The first run after a cache change is cold.**"
        )
    lines.append("")
    lines.append(f"Generated {generated:%Y-%m-%d %H:%M} UTC by `scripts/ci_speed.py`.")
    return "\n".join(lines) + "\n"


# --- GitHub and git access, kept out of the pure functions above so tests run offline ---


def github_token() -> str:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        return token
    return subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, check=True).stdout.strip()


def github_get(path: str, token: str) -> dict[str, Any]:
    request = urllib.request.Request(
        f"{API}/{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.loads(response.read())


def repository() -> str:
    if os.environ.get("GITHUB_REPOSITORY"):
        return os.environ["GITHUB_REPOSITORY"]
    url = subprocess.run(["git", "remote", "get-url", "origin"], capture_output=True, text=True, check=True).stdout
    return re.sub(r"(\.git)?\s*$", "", url.split("github.com", 1)[1].lstrip(":/"))


def git_contains(ancestor: str, sha: str) -> bool:
    result = subprocess.run(
        ["git", "merge-base", "--is-ancestor", ancestor, sha], cwd=REPO_ROOT, capture_output=True, check=False
    )
    return result.returncode == 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--milestones", type=Path, default=DEFAULT_MILESTONES)
    parser.add_argument("--runs", type=int, default=100, help="completed runs to read per workflow (newest first)")
    parser.add_argument("--output", type=Path, help="also write the report to this file")
    args = parser.parse_args(argv)

    token, repo = github_token(), repository()
    workflows = github_get(f"repos/{repo}/actions/workflows?per_page=100", token)["workflows"]
    runs: list[dict[str, Any]] = []
    for workflow in workflows:
        if not workflow["path"].endswith(("-container.yml", "ssh-server.yml", "far-manager.yml")):
            continue
        page = github_get(
            f"repos/{repo}/actions/workflows/{workflow['id']}/runs?status=completed&per_page={min(args.runs, 100)}",
            token,
        )
        runs.extend(page["workflow_runs"])
    samples = samples_from_runs(
        runs, lambda run_id: github_get(f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100", token)["jobs"]
    )

    now = datetime.now(UTC)
    report = "\n".join(markdown(m, compare(samples, m, git_contains), now) for m in load_milestones(args.milestones))
    print(report)
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
