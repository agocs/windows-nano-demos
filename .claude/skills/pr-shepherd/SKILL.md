---
name: pr-shepherd
description: Move pull requests in this repo through rebase, conflict resolution and merge safely - including stacked PRs and the root README image list that every image PR edits. Use when a PR conflicts with main, when a stack needs retargeting, or when asked to merge once checks pass.
---

# PR shepherd

## Bring a branch up to date with main

Work in the branch's own worktree. Never use the user's main checkout.

```bash
git fetch origin
git merge origin/main        # or: git rebase origin/main
git diff --name-only --diff-filter=U   # files still in conflict
```

- **List-like files**, where both sides only add lines (the root `README.md` image table, `docs/adr/README.md`), are resolved by keeping both sides:

  ```bash
  uv run python scripts/union_merge.py README.md docs/adr/README.md && git add README.md docs/adr/README.md
  ```

- **Anything else**, such as workflows, Dockerfiles or scripts, needs reading and resolving by hand. Never union code.
- **Before any push**, check that the merge or rebase actually finished. `git status` must not say "rebase in progress" or "You have unmerged paths". Pushing mid-rebase pushes the wrong commit.
- After resolving, run `uv run pre-commit run --all-files`, then push. Use `--force-with-lease`, never `--force`, after a rebase.

## Stacked pull requests

- A PR based on another PR's branch shows only its own diff. When the lower PR merges, retarget the upper one: `gh pr edit <n> --base main`. GitHub only does it automatically if the lower branch is deleted.
- Merging a PR that is part of a stack needs the asynchronous merge API, because `gh pr merge` refuses:

  ```bash
  sha=$(gh pr view <n> --json headRefOid -q .headRefOid)
  gh api -X PUT repos/zippy1981/windows-nano-demos/pulls/<n>/merge-async -f merge_method=merge -f sha=$sha
  ```

  Pinning `sha` makes the merge fail if someone pushed after the checks ran. Never pass `bypass_rules`.

## Merging

- Merge only when every check on the current head commit has passed (`gh pr checks <n>`), and only when the user asked for it. Never use `--admin`.
- Squash or merge commit: follow what the user asked for. The default is a merge commit.
- After the merge, delete the remote branch only when no open PR is based on it. Check with `gh pr list --base <branch>`.
- `gh pr merge` may print `'main' is already used by worktree`. The merge on GitHub still happened; only the local cleanup step failed.
