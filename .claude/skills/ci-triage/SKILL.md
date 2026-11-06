---
name: ci-triage
description: Find out why a GitHub Actions run, PR or branch failed in this repo, cheaply. It prints only each failed job's failing step and error lines instead of whole logs. Use whenever a check is red, before reading any log, and when waiting for CI to finish.
---

# CI triage

Whole job logs are tens of thousands of tokens, almost all noise. Always start with the triage script:

```bash
uv run python scripts/ci_triage.py --pr 42           # every failed check on a pull request
uv run python scripts/ci_triage.py --run 42080211633 # one workflow run
uv run python scripts/ci_triage.py --branch main     # the latest failed run on a branch
```

For each failed job it prints the job, the step that failed, and the lines that look like errors, plus the last few lines, with timestamps and checkout noise removed. Exit code 1 means something failed; 0 means nothing did.

Only if that isn't enough, read one job's failed-step log, and only its tail:

```bash
gh run view --job <job-id> --log-failed | tail -60
```

## Waiting for CI

Don't poll in a tight loop, and don't stream logs while waiting. Either:

- start the `ci-watcher` agent, which waits and reports only the outcome, or
- run one background command and wait for its notification:

  ```bash
  until [ "$(gh run view <run-id> --json status -q .status)" = completed ]; do sleep 120; done; uv run python scripts/ci_triage.py --run <run-id>
  ```

## Known failure patterns in this repo

| Symptom | Usual cause |
| --- | --- |
| `hcs ... timeout` or `context deadline exceeded` | Host under load, or a Hyper-V build without `--memory 4g`. Re-run the job once. |
| A job abandoned, or a gap of several hours | The host went into Modern Standby. See DEVELOPER.md and the host doctor agent. |
| `returned 401` from `registry-1.docker.io` | The Docker Hub repository has never been pushed. That's handled in `refresh_matrix.py`. |
| `error obtaining VCS status: exit status 128` | `go build` in a layer after the clone. Build with `-buildvcs=false`. |
| `0xC0000135` or `0xC0000139` | A missing DLL or entry point on nanoserver. See DEVELOPER.md. |
| `ruff format --check` fails only in CI | The pull request merged with main brings in unformatted code. Run `uv run pre-commit run --all-files`. |
