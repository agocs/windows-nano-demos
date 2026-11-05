"""One compact snapshot of the repo's moving parts: open PRs and their checks, the runner fleet, the CI queue, and
local worktrees. Use it instead of running gh and git by hand.

    uv run python scripts/repo_status.py
"""

from __future__ import annotations

import json
import subprocess
import sys
from collections import Counter
from collections.abc import Callable
from typing import Any

Run = Callable[[list[str]], str]


def run(args: list[str]) -> str:
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def summarize_checks(rollup: list[dict[str, Any]]) -> str:
    """'3 pass, 1 fail, 2 pending' from a PR's statusCheckRollup."""
    counts: Counter[str] = Counter()
    for check in rollup:
        state = (check.get("conclusion") or check.get("state") or check.get("status") or "").upper()
        if state in {"SUCCESS", "NEUTRAL", "SKIPPED"}:
            counts["pass" if state == "SUCCESS" else "skip"] += 1
        elif state in {"FAILURE", "TIMED_OUT", "CANCELLED", "ERROR", "STARTUP_FAILURE"}:
            counts["fail"] += 1
        else:
            counts["pending"] += 1
    return ", ".join(f"{n} {k}" for k, n in sorted(counts.items())) or "no checks"


def parse_worktrees(porcelain: str) -> list[dict[str, str]]:
    trees, current = [], {}
    for line in porcelain.splitlines() + [""]:
        if not line:
            if current:
                trees.append(current)
            current = {}
        elif " " in line:
            key, value = line.split(" ", 1)
            current[key] = value
        else:
            current[line] = "yes"
    return trees


def section_prs(run_cmd: Run) -> list[str]:
    prs = json.loads(
        run_cmd(["gh", "pr", "list", "--json", "number,title,headRefName,baseRefName,isDraft,statusCheckRollup"])
    )
    lines = ["## Open pull requests"]
    for pr in sorted(prs, key=lambda p: p["number"]):
        draft = " (draft)" if pr["isDraft"] else ""
        base = "" if pr["baseRefName"] == "main" else f" -> {pr['baseRefName']}"
        lines.append(f"- #{pr['number']}{draft} {pr['headRefName']}{base}: {summarize_checks(pr['statusCheckRollup'])}")
    return lines


def section_runners(run_cmd: Run) -> list[str]:
    repo = run_cmd(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]).strip()
    runners = json.loads(run_cmd(["gh", "api", f"repos/{repo}/actions/runners"]))["runners"]
    queued = json.loads(run_cmd(["gh", "api", f"repos/{repo}/actions/runs?status=queued&per_page=100"]))["total_count"]
    busy = sum(r["busy"] for r in runners)
    online = sum(r["status"] == "online" for r in runners)
    return ["## CI", f"- runners: {online}/{len(runners)} online, {busy} busy", f"- queued workflow runs: {queued}"]


def section_worktrees(run_cmd: Run) -> list[str]:
    lines = ["## Worktrees"]
    for tree in parse_worktrees(run_cmd(["git", "worktree", "list", "--porcelain"])):
        path = tree["worktree"]
        branch = tree.get("branch", "(detached)").removeprefix("refs/heads/")
        try:
            dirty = len(run_cmd(["git", "-C", path, "status", "--porcelain"]).splitlines())
        except subprocess.CalledProcessError:
            dirty = -1
        flags = [f"{dirty} dirty" if dirty else "clean"] + (["locked"] if "locked" in tree else [])
        lines.append(f"- {path} [{branch}] {', '.join(flags)}")
    return lines


def main(argv: list[str] | None = None, run_cmd: Run = run) -> int:
    sections = []
    for section in (section_prs, section_runners, section_worktrees):
        try:
            sections.append("\n".join(section(run_cmd)))
        except (subprocess.CalledProcessError, KeyError, json.JSONDecodeError) as error:
            sections.append(f"## {section.__name__.removeprefix('section_')}\n- unavailable: {error}")
    print("\n\n".join(sections))
    return 0


if __name__ == "__main__":
    sys.exit(main())
