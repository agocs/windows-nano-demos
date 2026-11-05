"""Print why CI failed, compactly: for each failed job, its failing step and the error lines from its log.

Fetching whole job logs costs far more tokens than reading them is worth. This prints only the step that failed and
the lines that look like errors, plus the last few lines before the job ended.

    uv run python scripts/ci_triage.py --pr 42          # the latest run of every failed check on a pull request
    uv run python scripts/ci_triage.py --run 4208021163 # one workflow run
    uv run python scripts/ci_triage.py --branch main    # the latest failed run on a branch

It uses the authenticated `gh` CLI.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections.abc import Callable, Iterable
from typing import Any

ERROR = re.compile(
    r"(##\[error\]|\berror\b|\bfailed\b|\bfailure\b|exception|traceback|assert|denied|not found|timed out|"
    r"exit code [1-9]|0xc0000\w+|returned [45]\d\d|\bFAILED\b|\bE\s{2,})",
    re.IGNORECASE,
)
NOISE = re.compile(
    r"(Node\.js 20 is deprecated|##\[group\]|##\[endgroup\]|^\s*$|% Total|Dload|git config --local|"
    r"includeif|git-credentials|Removing credentials|Post job cleanup|Cleaning up orphan|safe\.directory|"
    r"^git version|Temporarily overriding HOME|Removing SSH command|Removing HTTP extra header|"
    r"\[command\].*git(\.exe)?\"? (config|submodule|version))",
    re.IGNORECASE,
)
# `gh run view --log` lines are "<job>\t<step>\t<time> <text>"; job and step names can contain spaces
TIMESTAMP = re.compile(r"^[^\t]*\t[^\t]*\t\d{4}-\d\d-\d\dT[\d:.]+Z ?|^\d{4}-\d\d-\d\dT[\d:.]+Z ?")

Gh = Callable[[list[str]], str]


def gh(args: list[str]) -> str:
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=True).stdout


def failed_jobs(jobs: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Jobs that failed or timed out, each with the name of its first failed step."""
    out = []
    for job in jobs:
        if job.get("conclusion") not in {"failure", "timed_out", "startup_failure"}:
            continue
        steps = job.get("steps") or []
        step = next((s["name"] for s in steps if s.get("conclusion") in {"failure", "timed_out"}), "(no failed step)")
        # gh run view --json calls it databaseId; the REST API calls it id
        job_id = job.get("databaseId", job.get("id"))
        out.append({"id": job_id, "name": job["name"], "conclusion": job["conclusion"], "step": step})
    return out


def error_lines(log: str, tail: int = 8, limit: int = 30) -> list[str]:
    """The error-looking lines of a job log, plus its last `tail` lines, without timestamps and noise."""
    lines = [TIMESTAMP.sub("", line).rstrip() for line in log.splitlines()]
    lines = [line for line in lines if line and not NOISE.search(line)]
    picked = [line for line in lines if ERROR.search(line)]
    seen: set[str] = set()
    result = []
    for line in [*picked[-limit:], *lines[-tail:]]:
        if line not in seen:
            seen.add(line)
            result.append(line[:300])
    return result


def runs_for_pr(pr: int, run_gh: Gh) -> list[int]:
    checks = json.loads(run_gh(["pr", "checks", str(pr), "--json", "state,link"]) or "[]")
    ids = {
        int(m.group(1))
        for c in checks
        if c.get("state") == "FAILURE"
        for m in [re.search(r"/runs/(\d+)", c["link"])]
        if m
    }
    return sorted(ids)


def report(run_id: int, run_gh: Gh) -> str:
    run = json.loads(run_gh(["run", "view", str(run_id), "--json", "name,headBranch,headSha,conclusion,url,jobs"]))
    lines = [f"## {run['name']} [{run['headBranch']} {run['headSha'][:7]}] {run['conclusion']}  {run['url']}"]
    failures = failed_jobs(run.get("jobs", []))
    if not failures:
        lines.append("No failed jobs.")
    for job in failures:
        lines.append(f"### {job['name']}: {job['conclusion']} at step '{job['step']}'")
        try:
            log = run_gh(["run", "view", "--job", str(job["id"]), "--log-failed"])
        except subprocess.CalledProcessError:
            log = ""
        lines += [f"    {line}" for line in error_lines(log)] or ["    (no log available yet)"]
    return "\n".join(lines)


def main(argv: list[str] | None = None, run_gh: Gh = gh) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--pr", type=int)
    target.add_argument("--run", type=int)
    target.add_argument("--branch")
    args = parser.parse_args(argv)
    if args.run:
        runs = [args.run]
    elif args.pr:
        runs = runs_for_pr(args.pr, run_gh)
    else:
        listed = json.loads(
            run_gh(["run", "list", "--branch", args.branch, "--status", "failure", "-L", "1", "--json", "databaseId"])
        )
        runs = [r["databaseId"] for r in listed]
    if not runs:
        print("No failed runs.")
        return 0
    print("\n\n".join(report(run, run_gh) for run in runs))
    return 1


if __name__ == "__main__":
    sys.exit(main())
