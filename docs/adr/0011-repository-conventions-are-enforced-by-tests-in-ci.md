# 0011. Repository conventions are enforced by tests in CI

- Status: Accepted
- Date: 2026-11-04
- Deciders: Justin Dearing
- Related: [0003](0003-self-hosted-nanoserver-runners-using-host-docker-daemon-via-named-pipe.md), [0008](0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md), [0009](0009-all-image-builds-use-one-reusable-workflow.md), [0010](0010-python-tooling-uses-uv-with-the-python-version-from-uv-python.md)

## Context

The conventions in these ADRs were enforced only by review and by agent prompts. Most agent-written branches drifted somewhere: a missing fork guard, a matrix leg left out, `WINDOWS_VERSION` defaulting to the wrong version, or a workflow that couldn't run on the self-hosted runners. Some of these are also security controls. A self-hosted job without the fork guard can run code from strangers on a machine with host docker access.

## Decision

A pytest suite under `tests/`, run with uv as described in [0010](0010-python-tooling-uses-uv-with-the-python-version-from-uv-python.md), checks the conventions. The `Repo tests` workflow runs it on GitHub-hosted `ubuntu-latest` for every push and pull request. It checks that:

- **Runner:** every job that runs `docker` uses the self-hosted runner labels `[self-hosted, windows, docker]` from [0003](0003-self-hosted-nanoserver-runners-using-host-docker-daemon-via-named-pipe.md). Any job on those labels has the fork guard and a `timeout-minutes`. Jobs that don't use docker run on GitHub-hosted runners.
- **Reusable workflow:** it keeps the runner labels, the `2019`, `2022`, `2025` matrix with `fail-fast: false`, `--memory` on `docker build`, and an `always()` cleanup step.
- **Images:** every image folder with a `Dockerfile` (under `nano-server/` or `server-core/`, [0012](0012-images-live-in-a-directory-for-their-base-image.md)):
  - has a caller workflow that uses the reusable workflow with `context` set to that folder
  - lists the folder and the reusable workflow in its path filters
  - has a `smoke-test.ps1`
  - follows [0008](0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md): `ARG WINDOWS_VERSION=2025`, the `BASE_IMAGE` argument and a final `FROM ${BASE_IMAGE}`
  - has a `build.cmd` that defaults to 2025 and forwards `BASE_IMAGE`
- **Actions:** third-party actions are pinned to a commit SHA. Actions owned by GitHub (`actions/*`) may use a version tag.

## Consequences

- A new image or workflow that breaks a convention fails CI with a message naming the file and the rule.
- Changing a convention means changing its ADR, the tests, and every affected file in the same pull request.
- Open branches written before this ADR must be updated to the reusable workflow and the 2025 default before they can merge.

## Alternatives considered

- **actionlint and hadolint only.** They catch syntax and generic mistakes but know nothing about this repo's rules, such as the runner labels, the fork guard or the version default.
- **Rely on the governance agent.** It is useful for audits but runs only on request. Tests run on every change.
- **A PowerShell Pester suite.** Pester runs on the Windows runners, but YAML parsing in pwsh needs a third-party module. Tests on the Linux hosted runners also keep convention checks off the self-hosted machine.
