---
name: repo-status
description: One compact snapshot of this repo's state - open PRs with check counts, the self-hosted runner fleet and CI queue, and every local worktree with its dirty and locked state. Use at the start of a session, before reporting status to the user, and instead of running gh pr list, gh api runners and git worktree list by hand.
---

# Repo status

```bash
uv run python scripts/repo_status.py
```

It prints three sections:

- **Open pull requests:** number, branch, base (when it isn't `main`), draft flag, and check counts (`3 pass, 1 fail, 2 pending`)
- **CI:** runners online and busy, plus queued workflow runs
- **Worktrees:** path, branch, and `clean`, `N dirty` or `locked`

If one section can't be read, for example the API is unreachable, it says so and still prints the others.

Follow-ups:

- A red PR: run the `ci-triage` skill (`scripts/ci_triage.py --pr <n>`).
- Busy runners and a long queue: see "Waiting for CI" in the `ci-triage` skill. Don't poll.
- A dirty or locked worktree: never remove it without asking. A locked one belongs to a running agent.
