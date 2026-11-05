# Codecov coverage reporting

## Goal

Every push and pull request uploads the Python test coverage and test results to [Codecov](https://about.codecov.io/). Pull requests get a Codecov status check and a short comment that shows the coverage of the lines they change. The README shows a coverage badge. The local 95% gate (`fail_under` in `pyproject.toml`, from PR #47) stays the hard rule: Codecov adds history, patch coverage and per-test failure tracking on top of it, and is never the only gate.

## Context

- `Repo tests` (`.github/workflows/repo-tests.yml`) runs `uv run pytest -v --cov` on `ubuntu-latest` and fails below 95% of `scripts/`. It writes the coverage table to the run summary. Nothing leaves GitHub.
- The repo is public, and Codecov is free for public repositories.
- The workflow runs on a GitHub-hosted runner and needs no self-hosted runner, so uploading doesn't touch the shared host (ADR 0003).
- Fork pull requests get no repository secrets. Codecov accepts tokenless uploads from forks of public repositories, so fork PRs still report coverage without a secret.
- ADR 0011 requires third-party actions to be pinned to a commit SHA. `codecov/codecov-action` is third-party.
- The PowerShell under `scripts/` (`Remove-DockerArtifacts.ps1`) and the image smoke tests are not measured. Pester can write JaCoCo coverage, which Codecov reads, so they can be added later under their own flag.

## Decisions

1. **Upload from `Repo tests`, not a new workflow.** The coverage is already computed there. Add `--cov-report=xml` and `--junitxml=junit.xml` to the pytest step, then one `codecov/codecov-action` step for coverage and one for test results, both `if: ${{ !cancelled() }}` so a failing test run still reports.
2. **Authenticate with a repository upload token** in the `CODECOV_TOKEN` repository secret for pushes and same-repo PRs. Fork PRs upload tokenless. The owner creates the token (see [Setting up the Codecov account](#setting-up-the-codecov-account)). No agent ever reads, writes or prints it.
3. **Never use `pull_request_target`** to get the token into fork PRs. That would run fork code with secrets.
4. **`codecov.yml` in the repo root** sets:
   - `coverage.status.project`: target 95%, threshold 0.5%
   - `coverage.status.patch`: target 90%
   - the PR comment layout `condensed_header, diff, files`, with `require_changes: true` so PRs that don't change coverage get no comment
   - `ignore: ["tests/**"]`
   - one flag, `python`, so a later `powershell` flag can be added without mixing the numbers
5. **The Codecov checks are informational at first** (`informational: true`) for two weeks. Then the owner decides whether `codecov/patch` becomes a required check. The local `fail_under = 95` is required from day one, because it already is.
6. **Uploads fail the job only on `main`** (`fail_ci_if_error: ${{ github.ref == 'refs/heads/main' }}`). A Codecov outage must not block PRs, but a broken upload on `main` should be noticed.
7. **Badge:** a Codecov badge next to the title in the root README, linked to the Codecov dashboard.
8. **ADR:** amend ADR 0011 (conventions enforced by tests) with a "Coverage" section: the 95% local gate, Codecov reporting, and the never-`pull_request_target` rule. No new ADR, since this extends an existing decision rather than making a new hard-to-reverse one.

## Plan

### Phase 0: Owner setup (manual, outside the repo)

- [x] **owner**: Create the Codecov account and connect the repo, and add `CODECOV_TOKEN` as a repository secret, as described in [Setting up the Codecov account](#setting-up-the-codecov-account). Accept: the repo appears on the Codecov dashboard, and `gh secret list` shows `CODECOV_TOKEN` (name only).

### Phase 1: Upload

- [x] **workflow-author**: In `repo-tests.yml`, add `--cov-report=xml --junitxml=junit.xml` to the pytest step. Add the coverage and test-results upload steps with `codecov/codecov-action`, pinned to a commit SHA with a version comment (ADR 0011). Pass `token: ${{ secrets.CODECOV_TOKEN }}`, `files: coverage.xml` / `junit.xml`, `flags: python`, and `fail_ci_if_error` per Decision 6. Accept: actionlint is clean, `tests/test_workflows.py` passes (pinned action), and a PR run shows the upload steps succeeding.
- [x] **python-author**: Add `coverage.xml`, `junit.xml` and `.coverage.*` to `.gitignore` if they're missing, and a convention test that `repo-tests.yml` never uses `pull_request_target` and passes `secrets.CODECOV_TOKEN` only to the Codecov steps. Accept: `uv run pytest --cov` passes at 95% or more.
- [x] **workflow-author**: Add `codecov.yml` per Decision 4, and validate it with `curl --data-binary @codecov.yml https://codecov.io/validate`. Accept: the validator returns "Valid!".

### Phase 2: Visibility

- [x] **container-author**: Add the Codecov badge to the root `README.md` and a "Coverage" paragraph to `DEVELOPER.md`. It covers where to see coverage, what the 95% and patch targets are, and that the local gate is the one that blocks. Accept: markdownlint passes.
- [x] **adr**: Amend ADR 0011 with the Coverage section (Decision 8). Accept: the ADR index is unchanged except the amended date, and markdownlint passes.

### Phase 3: Token savers for test work

- [x] **python-author**: Apply the test-output changes in [Reducing tokens spent on tests](#reducing-tokens-spent-on-tests) (items 1 to 3). Accept: a failing test still prints its assertion message, a full passing run prints at most a few lines, and coverage tables list only files below 100%.
- [x] **python-author**: Add `scripts/coverage_gaps.py` and the `coverage-gaps` skill (item 4). Accept: it prints, for each file below 100%, the uncovered line ranges with the enclosing function name and at most 3 lines of code each. Its own tests keep the 95% gate.
- [x] **python-author**: Make `scripts/ci_triage.py` strip ANSI colour codes and, for pytest logs, keep only `FAILED`, `ERROR`, `E` and the coverage-gate lines (item 5). Accept: unit tests with a captured pytest log.
- [x] **planning**: Update `.claude/agents/python-author.md`, `python-fixer.md` and `ci-watcher.md`, and add the `codecov` skill (items 6 to 8). Accept: governance finds no agent that reads a whole CI log or runs the full suite verbosely.

### Phase 4: Later (not in this PR)

- [ ] **powershell-author**: Pester tests for `scripts/*.ps1` with `-CodeCoverage` and `-CodeCoverageOutputFileFormat JaCoCo`, uploaded under a `powershell` flag. Accept: the flag shows on the Codecov dashboard.

## Setting up the Codecov account

Done once by the repo owner. It needs no agent and no token handling by agents.

1. Go to <https://app.codecov.io/login> and choose **Sign in with GitHub**. Authorize the Codecov OAuth app. Codecov reads your public repositories and org membership.
2. When asked, **install the Codecov GitHub App** on the `zippy1981` account. Choose **Only select repositories** and pick `windows-nano-demos`. The app posts the PR comments and status checks. Without it, uploads still work but PRs get no comment or check.
3. In Codecov, open **zippy1981 → windows-nano-demos**. If it isn't listed, use **Add repository** or **Resync** at the top of the repository list.
4. Open the repository's **Configuration → General** page and copy the **repository upload token**. Prefer this to the global (org) upload token, because it can only upload to this repository.
5. Add it as a GitHub **repository secret**, not an environment secret, because `Repo tests` runs on every branch:
   - in the browser: **Settings → Secrets and variables → Actions → New repository secret**, name `CODECOV_TOKEN`
   - or in a terminal, which prompts for the value so it never lands in shell history: `gh secret set CODECOV_TOKEN --repo zippy1981/windows-nano-demos`
6. Optional, under **Configuration → General** in Codecov:
   - leave **Token authentication for public repositories** on, so only CI with the token can upload for `main`
   - turn on **Test Analytics** if it isn't on by default, so failing and flaky tests are tracked per test name
7. After the first upload from `main`, copy the badge Markdown from **Configuration → Badges & Graphs** and add it to the README (Phase 2).

Rotating the token: regenerate it on the same Codecov page and run `gh secret set CODECOV_TOKEN` again. Revoking access: uninstall the Codecov GitHub App under GitHub **Settings → Applications**.

## Reducing tokens spent on tests

Most tokens in test work go on reading output: a verbose run of 386 parametrized tests, pytest dumping a whole README in a failed `in` assertion, ANSI colour codes in CI logs, and reading whole scripts to find what isn't covered. Suggested changes:

1. **Quieter pytest by default.** In `pyproject.toml`, set `addopts = "-q -rfE --no-header --tb=short"`. `-rfE` lists only failures and errors, not every skip and xfail, as `-ra` does. In `repo-tests.yml`, use `-q` instead of `-v`, since Codecov Test Analytics keeps the per-test record that `-v` was printing. The pre-commit hook already uses `-q`.
2. **Coverage tables without the 100% files:** use `--cov-report=term-missing:skip-covered` in CI and pre-commit, so a passing run prints a few lines instead of a row per script.
3. **Short assertion messages for big values.** Tests that check `x in readme` or `x in log` should state what was looked for and not let pytest print the haystack. Use `assert needle in text, f"... {needle!r} missing"` with `--tb=short`, or compare a boolean such as `found = needle in text`, then `assert found, msg`. A `tests/conftest.py` `pytest_assertrepr_compare` hook can also truncate any string over 500 characters. Add a convention test or a ruff rule note to python-author.
4. **`coverage-gaps` skill** backed by `scripts/coverage_gaps.py`. It reads `coverage.json` (`--cov-report=json`) and prints only the uncovered ranges, with their function names and a few lines of code each. Writing the missing tests then needs that output plus the function signature, not the whole file.
5. **`ci_triage.py` understands pytest:** strip ANSI codes (they showed up as `^[[31;1m` noise in this session's triage output), drop `PASSED` lines, and keep `FAILED`, `ERROR`, `E` lines and the "Required test coverage" line.
6. **`codecov` skill** that queries Codecov's public API for a PR, for example `https://api.codecov.io/api/v2/github/zippy1981/repos/windows-nano-demos/compare/?pullid=<n>`, and prints the totals and the changed files below target. Public repos need no token for reads. One small JSON response replaces downloading CI logs to learn the coverage.
7. **python-author agent:**
   - run `uv run pytest -q --lf` (last failed) or `-k <name>` while iterating, and the full `--cov` run once at the end
   - use the `coverage-gaps` skill rather than reading scripts to find untested code
   - follow the `tests/test_script_io.py` pattern (fake `gh`, `git` and HTTP through monkeypatch or injected callables), so tests stay offline and fast
   - parametrize over repo items (the rule from PR #47)
8. **ci-watcher and python-fixer:**
   - ci-watcher reports a coverage-gate failure as the "Required test coverage" line plus the `codecov` skill's file list, never the full table
   - python-fixer (haiku) stays limited to ruff. Coverage gaps go to python-author (sonnet), because writing good tests isn't a mechanical fix.

## Risks

- **Codecov outage or rate limit.** Mitigation: uploads can fail CI only on `main` (Decision 6), and the local gate keeps blocking regardless.
- **Token leak.** Mitigation:
  - repository-scoped upload token
  - never `pull_request_target`
  - a convention test that the token goes only to the Codecov steps
  - agents never handle it
- **Noisy PR comments.** Mitigation: `require_changes: true` and the condensed layout.
- **Coverage numbers that differ between local runs and Codecov**, from path mapping between Windows and Linux. Mitigation: coverage runs only on `ubuntu-latest` in CI, and `coverage.xml` uses relative paths (`[tool.coverage.run] relative_files = true`).

## Owners

| Agent | Tasks |
| --- | --- |
| owner (manual) | Codecov account, GitHub App, `CODECOV_TOKEN` secret, deciding whether `codecov/patch` becomes required |
| `workflow-author` | Upload steps in `repo-tests.yml`, `codecov.yml` |
| `python-author` | `.gitignore`, convention test, quieter pytest, `coverage_gaps.py`, `ci_triage.py` pytest mode |
| `container-author` | README badge, `DEVELOPER.md` coverage paragraph |
| `adr` | ADR 0011 amendment |
| `planning` | Agent and skill updates |
| `powershell-author` | Pester coverage (later) |
