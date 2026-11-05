---
name: codecov
description: Read this repo's coverage from Codecov's public API (totals, a pull request's patch coverage, and the changed files below target) in one small request, instead of downloading CI logs. Use when a Codecov check is red or pending, when asked what a PR does to coverage, or when reporting coverage.
---

# Codecov

Coverage and test results from `Repo tests` are uploaded to Codecov (`plans/codecov.md`). The repo is public, so reading needs no token. Never print, read or set `CODECOV_TOKEN`: the owner manages it.

```bash
# A pull request: head and base totals, patch coverage, and the files whose coverage changed
curl -s "https://api.codecov.io/api/v2/github/zippy1981/repos/windows-nano-demos/compare/?pullid=<n>" \
  | jq '{totals: .totals, files: [.files[] | select(.totals.patch.coverage != null and .totals.patch.coverage < 90)
         | {name: .name.head, patch: .totals.patch.coverage}]}'

# main: the latest total
curl -s "https://api.codecov.io/api/v2/github/zippy1981/repos/windows-nano-demos/totals/?branch=main" | jq '.totals.coverage'
```

The checks are `codecov/project` (target 95%) and `codecov/patch` (target 90%), set in `codecov.yml`. Both are informational for now. The gate that blocks a merge is the local `fail_under = 95` in the `Test` step. When that fails, use the `coverage-gaps` skill, not Codecov.

If a fresh PR has no Codecov data yet, the upload step probably hasn't finished. Check it with the `ci-triage` skill (`--pr <n>`) rather than reading the log.
