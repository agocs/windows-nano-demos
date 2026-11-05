# Patch Tuesday image refresh

## Goal

Within a day of Microsoft publishing new nanoserver base images after Patch Tuesday, every image in this repo is rebuilt for ltsc2019, ltsc2022, and ltsc2025, smoke-tested, and published to Docker Hub under the agreed tags, with no manual steps. Failures open a GitHub issue. The runner fleet moves to the new runner image the same week.

## Context

- Patch Tuesday is the second Tuesday of each month. MCR usually updates `mcr.microsoft.com/windows/nanoserver:ltsc2019|ltsc2022|ltsc2025` (and servercore) the same day with a new OS build revision (for example `10.0.20348.<rev>`) and KB-named tags such as `ltsc2022-KB5044281`. Out-of-band releases happen a few times a year.
- Images today: `nano-server-gh-runner/` (follows the `ARG WINDOWS_VERSION` / `ARG BASE_IMAGE` / `FROM ${BASE_IMAGE}` convention and has `.github/workflows/gh-runner-container.yml`) and `nano-server-php/` (hardcodes `FROM mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64`, copies VC++ DLLs and 7-Zip from a host `system32/` folder, and has no workflow, so it can't build in CI yet).
- CI runs on `[self-hosted, windows, docker]`: nanoserver runner containers with PowerShell 7, MinGit, and the docker CLI on the host daemon's named pipe. There are no workspace bind mounts, and fork pull requests are skipped. Markdown lint runs on `ubuntu-latest`.
- Nothing publishes to Docker Hub from CI today. `windows-image-publisher` pushes by hand. Runner containers are started by `nano-server-gh-runner/run-runner.ps1` from a local `windows-nano-gh-runner:2022` tag and are never recreated automatically.
- Nothing cleans images off the runner host, and every CI build adds layers.

## Decisions

1. **Detect changes by digest, statelessly.** A detection job on `ubuntu-latest` reads the current MCR digest and OS version for each ltsc tag with `docker manifest inspect`, and compares them with the `org.opencontainers.image.base.digest` label on the published Docker Hub image. Changed means rebuild. No state file is committed. ADR: [0004 Rebuild all images on base-image digest change](../docs/adr/0004-rebuild-all-images-on-base-image-digest-change.md).
2. **Poll daily rather than guess the date.** GitHub cron ORs day-of-month and day-of-week, so "the Wednesday after the second Tuesday" (`0 6 9-15 * 3`) would actually fire every Wednesday and on the 9th to 15th. Run the detection at 06:00 and 18:00 UTC every day instead. On a quiet day it costs one cheap `ubuntu-latest` job and builds nothing. The MCR tags list (`https://mcr.microsoft.com/v2/windows/nanoserver/tags/list`) is used only for the KB numbers in the summary.
3. **Rebuild every image for a Windows version when that version's base changes**, not only images whose layers would differ. ADR 0004.
4. **Pin the base by digest during the build.** Detection passes `BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc<ver>-amd64@sha256:<digest>`, so the image built is exactly the one detected, even if MCR moves the tag mid-run.
5. **Tags:** `:<ver>` (moving), `:<ver>-<os-build>` such as `:2022-10.0.20348.2849` (moving within an OS build), `:<ver>-YYYY-MM` (moving within a month), and `:<ver>-<os-build>-<git-sha7>` (immutable). Local builds keep `windows-nano-<x>:<ver>`. ADR: [0005 Tagging scheme for Windows images](../docs/adr/0005-tagging-scheme-for-windows-images.md).
6. **Build, test, and push in one job** on one runner, so the image pushed is the image tested on the same daemon. A failed smoke test skips the push for that leg only (`fail-fast: false`).
7. **Publish only from `main`, only from the refresh workflow** (scheduled or `workflow_dispatch` on `main`), with secrets in a `Docker Hub zippy1981` environment restricted to `main`. Per-image push and PR workflows build and test only. A merged tool bump is published by the next refresh run, which also rebuilds when the image folder's latest commit differs from the published image's `org.opencontainers.image.revision` label. ADR: [0006 Publish to Docker Hub only from main via scheduled workflow](../docs/adr/0006-publish-to-docker-hub-only-from-main-via-scheduled-workflow.md).
8. **Tool-version bumps are separate from base refreshes.** They arrive as reviewed PRs from `windows-deps-updater` and never in the same run as a base refresh, so a broken image can be blamed on one cause. ADR: [0007 Separate tool-version bumps from base-image refreshes](../docs/adr/0007-separate-tool-version-bumps-from-base-image-refreshes.md).
9. **Runner self-update from the host, not from a job.** A job can't safely replace the runner it is running on. A host scheduled task pulls the new runner image and recreates idle runner containers one at a time. The existing runner model is recorded in [0003 Self-hosted nanoserver runners using the host docker daemon via named pipe](../docs/adr/0003-self-hosted-nanoserver-runners-using-host-docker-daemon-via-named-pipe.md), and the version matrix in [0002 Build every image for ltsc2019, ltsc2022, and ltsc2025](../docs/adr/0002-build-every-image-for-ltsc2019-ltsc2022-and-ltsc2025.md).
10. **Scripts in PowerShell 7** under `scripts/`, because `pwsh` exists both on `ubuntu-latest` and in the runner image. Python is used only for the `ubuntu-latest` summary and pin-report tools.

## Plan

### Phase 0: Prerequisites

- [x] **adr**: Write ADRs 0001 to 0007 and the index. Accept: `docs/adr/README.md` lists all seven, and markdownlint passes.
- [x] **container-author**: Convert `nano-server-php/Dockerfile` to the `ARG BASE_IMAGE` / `FROM ${BASE_IMAGE}` convention, and replace the host `system32/` copy with a servercore build stage that supplies `vcruntime140.dll` and the other DLLs. Accept: `docker build --build-arg WINDOWS_VERSION=<v> nano-server-php` succeeds with an empty `system32/` for 2019, 2022, and 2025.
- [ ] **windows-dockerfile-reviewer**: Review the PHP Dockerfile change. Accept: no high-severity findings open.
- [ ] **windows-container-tester**: Write down the smoke-test commands for each image (PHP: `php -v`, `composer --version`, `node -v`, `npm -v`, `micro -version`; runner: the checks in `gh-runner-container.yml`). Accept: commands listed in each image README under "Smoke test".
- [x] **workflow-author**: Add `.github/workflows/php-container.yml` following the reference workflow. Accept: actionlint is clean, and all three matrix legs are green on a branch push.

### Phase 1: Shared build and metadata

- [x] **cicd-engineer**: Design a reusable workflow `.github/workflows/build-image.yml` (`workflow_call` with inputs `image`, `windows-version`, `base-image`, `publish`) that builds, labels, smoke-tests, optionally pushes, and always removes its images. Accept: design written into this plan's Decisions or an ADR amendment and agreed.
- [x] **workflow-author**: Implement `build-image.yml`, and make `gh-runner-container.yml` and `php-container.yml` call it with `publish: false`. Builds pass `--label` for `org.opencontainers.image.base.name`, `.base.digest`, `.revision` (`github.sha`), `.created`, and `.source`, plus `com.zippy1981.servercore.digest` for images with a servercore stage. Accept: actionlint is clean, both image workflows are green, and `docker image inspect` on a CI image shows all five labels.
- [x] **powershell-author**: Write `scripts/Get-BaseImageInfo.ps1`, which returns `{ version, repository, tag, digest, osVersion }` for each ltsc tag of nanoserver and servercore from `docker manifest inspect -v` (the `windows/amd64` entry's digest and `os.version`), with Pester tests that mock `docker`. Accept: Pester passes, PSScriptAnalyzer reports nothing, and it prints three objects on `ubuntu-latest` and on a runner.

### Phase 2: Detection

- [x] **powershell-author**: Write `scripts/Get-RefreshMatrix.ps1`, which, for each image folder and version, compares the MCR digest with the published image's base-digest label and the folder's last commit with its revision label (reading Docker Hub's registry API anonymously). It emits a JSON matrix of `{ image, windows-version, base-image, reason }`, where reason is `base-changed`, `source-changed`, `missing`, or `forced`. Accept: Pester tests cover each reason, plus "nothing to do" giving an empty matrix.
- [x] **python-author**: Write `scripts/refresh_summary.py`, which turns the matrix JSON and the MCR tags list into a Markdown job summary with OS builds and KB numbers. Stdlib only, with pytest and ruff. Accept: tests pass offline, and `ruff check` and `ruff format --check` are clean.
- [x] **workflow-author**: Write `.github/workflows/image-refresh.yml` with `schedule` (`0 6 * * *` and `0 18 * * *`) and `workflow_dispatch` (input `force: boolean`, input `images: string`). The `detect` job on `ubuntu-latest` runs both scripts and outputs the matrix. Accept: actionlint is clean, and a manual dispatch with no base change finishes with an empty matrix and a summary saying "nothing to rebuild".

### Phase 3: Rebuild, gate, publish

- [ ] **cicd-engineer**: Create the `Docker Hub zippy1981` environment restricted to `main`, holding `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a Docker Hub access token scoped to `zippy1981/windows-nano-*`, read/write). Accept: a run from a non-main branch can't read the secrets.
- [x] **workflow-author**: Add a `refresh` job to `image-refresh.yml`: `needs: detect`, `if: needs.detect.outputs.matrix != '[]'`, `strategy.matrix: ${{ fromJSON(needs.detect.outputs.matrix) }}`, `fail-fast: false`, `concurrency: refresh-${{ matrix.image }}-${{ matrix.windows-version }}`, the fork guard, and a call to `build-image.yml` with `publish: ${{ github.ref == 'refs/heads/main' }}`. The push step uses a per-job `DOCKER_CONFIG` directory, `docker login --password-stdin`, pushes the four tags from ADR 0005, then runs `docker logout` and deletes the directory in an `if: always()` step. Accept: a forced dispatch on `main` publishes all six image and version legs with all four tags, and a dispatch on a branch builds and tests without pushing.
- [ ] **windows-container-tester**: Check the first published set by pulling each tag and running the smoke tests. Accept: every pulled `:<ver>` tag reports the new OS build in `docker image inspect --format '{{.OsVersion}}'`.
- [ ] **container-author**: Add a "Tags" section to each image README describing ADR 0005's tags. Accept: markdownlint passes.

### Phase 4: Notifications

- [x] **workflow-author**: Add a `notify` job on `ubuntu-latest` (`needs: [detect, refresh]`, `if: always()`, `permissions: issues: write`). On failure it opens or updates one issue labelled `image-refresh` with the failed legs and run link. On success it comments and closes that issue. Accept: a forced failure (bad smoke-test command on a branch) opens the issue, and the next green run closes it.
- [ ] **workflow-author**: Add a staleness check to `detect`: if it is 3 or more days after Patch Tuesday and no base digest has changed since that Tuesday, open an `image-refresh` issue saying MCR hasn't updated. Accept: unit-tested date logic in `Get-RefreshMatrix.ps1` (Patch Tuesday computed correctly for 2026 and 2027).

### Phase 5: Runner host maintenance

- [ ] **powershell-author**: Write `scripts/Remove-StaleImages.ps1` (supports `-WhatIf`). For each `windows-nano-*` and `zippy1981/windows-nano-*` repository it keeps the tags for the two newest OS builds per Windows version, never removes an image used by a container (running or stopped), removes CI `-<sha>` tags older than 24 hours, then runs `docker image prune -f` and `docker builder prune -f --filter until=168h`. It reports the space reclaimed and the free space left. Accept: Pester tests with mocked `docker` cover the keep and remove rules, and a `-WhatIf` run on the host lists only stale images.
- [ ] **workflow-author**: Add `.github/workflows/runner-host-cleanup.yml`: weekly (`0 4 * * 0`) plus dispatch, on `[self-hosted, windows, docker]` with the fork guard (no PR trigger at all), running the cleanup script. It fails, which triggers the notify pattern, if free space is under 50 GB afterwards. Accept: one green run, with the reclaimed space in the job summary.
- [ ] **cicd-engineer**: Write `nano-server-gh-runner/Update-Runner.ps1` for the host. It pulls `zippy1981/windows-nano-gh-runner:<host-compatible ver>`, then for each runner container uses `gh api repos/<repo>/actions/runners` to wait until that runner is not `busy`, and recreates it from the new image through `run-runner.ps1 -Image ...`, one runner at a time. Register it as a Windows scheduled task running daily at 12:00 UTC. Update `run-runner.ps1` to default to the published image. Accept: after a refresh publishes a new runner image, every runner container's image ID matches the new tag within 24 hours, and no job was cancelled.
- [ ] **windows-host-doctor**: Add a check that the host OS itself was patched this month and is compatible with the runner image for process isolation. Accept: the doctor's report includes the host build and the runner image's `OsVersion`.

### Phase 6: Tool-version bumps (separate track)

- [ ] **python-author**: Write `scripts/check_pins.py`, which reads the `ENV` blocks of every Dockerfile and compares the pins with upstream (`nodejs.org/dist/index.json`, `windows.php.net/downloads/releases/releases.json`, GitHub releases for micro, PowerShell, MinGit, the runner, and docker). It outputs JSON and Markdown. Accept: pytest (offline, mocked) and ruff clean.
- [ ] **workflow-author**: Add `.github/workflows/pin-report.yml` on `ubuntu-latest`, monthly on the 20th (`0 7 20 * *`), away from Patch Tuesday. It opens or updates a `deps` issue with the report. Accept: one run produces the issue.
- [ ] **windows-deps-updater**: Apply bumps from the issue in a PR, one PR per image. Per-image workflows test it, and the next refresh run publishes it after merge (`source-changed`). Accept: the first bump PR is merged and published with a new `-<git-sha7>` tag.

### Phase 7: Governance and docs

- [ ] **governance**: Audit after Phases 1 to 5 land: fork guards on every self-hosted job, secrets only in the `Docker Hub zippy1981` environment, ADRs 0004 to 0007 reflected in workflows, all six legs present. Accept: no high-severity gaps.
- [ ] **adr**: Move ADRs 0004 to 0007 from Proposed to Accepted once their work lands, or supersede them if the design changed. Accept: index statuses match.
- [ ] **markdown-reviewer**: Review all new and changed Markdown. Accept: lint clean, with no stale paths.

## Implementation notes

Phases 0 to 4 are implemented, except the staleness check. The code differs from the plan as follows:

- **Shared workflow.** It is `build-windows-image.yml` from ADR 0009, not a new `build-image.yml`. It gained:
  - a `windows-versions` input (a JSON list defaulting to all three), so a refresh builds only the versions that changed
  - a `publish` input
  - optional `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` secrets
  - `environment: Docker Hub zippy1981`, set only when publishing from main
- **Labels.** Every build sets `org.opencontainers.image.revision`, `.source`, `.created` and `.title`. `.base.name` and `.base.digest` are set when the base is passed in, which a refresh always does, pinned by digest. `com.zippy1981.servercore.digest` is not implemented: a servercore helper stage pulls by tag, and changes to it are covered by `--force` dispatches.
- **Detection is Python, not PowerShell.** `Get-BaseImageInfo.ps1`, `Get-RefreshMatrix.ps1` and `refresh_summary.py` became one script, `scripts/refresh_matrix.py`. It has to read each image's caller workflow YAML to find its `base-image-overrides`, and the repo already has PyYAML, uv and pytest (ADR 0010). pwsh has no YAML parser without a third-party module. The script reads MCR and Docker Hub over their anonymous registry APIs rather than `docker manifest inspect`, so the detect job needs no docker. It is tested offline in `tests/test_refresh_matrix.py`.
- **source-changed** compares the published image's revision label with the folder's history (`git log <revision>..HEAD -- <folder>`), rather than comparing the folder's last commit hash. The revision label is the commit the image was built from, not the folder's last commit. A revision missing from history also counts as changed.
- **KB numbers** aren't in the summary yet. It lists the base OS build for each leg.
- **Notify** runs only for `main`, so branch dispatches don't open issues.
- **Convention tests** now also check that only the shared workflow and `image-refresh.yml` reference the Docker Hub secrets, that publishing requires `inputs.publish`, main and the `Docker Hub zippy1981` environment, that image workflows always build every version, that builds set the labels detection reads, and that `image-refresh.yml` has no pull request triggers.

The `Docker Hub zippy1981` environment exists, with `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`. Still to do: restrict its deployment branches to `main`, so a workflow pushed on another branch can't name the environment and read the token. The workflows only select it from main, but that alone doesn't protect the secret.

## Risks

- **MCR publishes late or out of band.** Daily polling picks it up whenever it lands, and the staleness issue flags a missing update.
- **A new base build breaks an image** (for example a `tar.exe` or `curl.exe` change). The smoke test blocks the push for that leg, the previous tags stay live, and the issue names the leg. Fix forward in a PR. A release can be held by not merging, because nothing else publishes.
- **ltsc2025 or ltsc2019 can't build on the host.** ltsc2025 images need a host at build 26100 or later. ltsc2019 builds on a newer host need Hyper-V isolation. `windows-host-doctor` checks both, and ADR 0002 records the host requirement.
- **Host compromise through the docker pipe.** Keep the fork guard on every self-hosted job and never add `pull_request_target`. Keep secrets in an environment limited to `main`. Delete `DOCKER_CONFIG` after each push, because runner containers persist between jobs.
- **Runner host disk fills.** Six legs a month plus CI images. The weekly cleanup and the 50 GB free-space alarm cover it.
- **A runner gets recreated mid-job.** `Update-Runner.ps1` only recreates runners the API reports as idle, one at a time.
- **Docker Hub rate limits or a token expires.** Authenticated pushes and reads, and the failure issue says when `docker login` failed. Rotate the token yearly. `governance` flags the expiry date if it is recorded in the environment description.
- **Windows base layers are foreign layers.** Pushes skip them by design, and pulls fetch them from MCR. This is expected, not an error.
- **A tool bump and a base change land the same day.** Both causes would be in one build, which breaks attribution. The refresh run reports `reason` per leg, and the 20th-of-month pin schedule keeps bumps away from Patch Tuesday week.

## Owners

| Agent | Tasks |
| --- | --- |
| `adr` | ADRs 0001 to 0007, status updates |
| `container-author` | PHP Dockerfile conversion, README "Tags" sections |
| `windows-dockerfile-reviewer` | Review of Dockerfile changes |
| `windows-container-tester` | Smoke-test definitions, verifying the first published set |
| `cicd-engineer` | Reusable workflow design, `Docker Hub zippy1981` environment, `Update-Runner.ps1` and runner rollout |
| `workflow-author` | `php-container.yml`, `build-image.yml`, `image-refresh.yml` (detect, refresh, notify, staleness), `runner-host-cleanup.yml`, `pin-report.yml` |
| `powershell-author` | `Get-BaseImageInfo.ps1`, `Get-RefreshMatrix.ps1`, `Remove-StaleImages.ps1`, with Pester tests |
| `python-author` | `refresh_summary.py`, `check_pins.py`, with pytest |
| `windows-host-doctor` | Host patch-level and compatibility check |
| `windows-deps-updater` | Monthly tool-version bump PRs |
| `governance` | Post-rollout audit |
| `markdown-reviewer` | Docs review |
