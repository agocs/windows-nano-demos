# 0002. Build every image for ltsc2019, ltsc2022, and ltsc2025

- Status: Accepted, amended by [0008](0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md) (default is now 2025)
- Date: 2026-11-04
- Deciders: Justin Dearing
- Related: [`.github/workflows/gh-runner-container.yml`](../../.github/workflows/gh-runner-container.yml), [0005](0005-tagging-scheme-for-windows-images.md)

## Context

Windows containers are tied to the host's OS build. A process-isolated container must match the host's Windows version, and a newer container than the host can't run at all. Users of these demos run Windows Server 2019, 2022, and 2025 and Windows 11, so a single-version image only serves some of them. The three supported long-term servicing channel (LTSC) nanoserver tags are `ltsc2019` (10.0.17763), `ltsc2022` (10.0.20348), and `ltsc2025` (10.0.26100).

## Decision

We will build and test every image for all three versions:

- Each `Dockerfile` takes `ARG WINDOWS_VERSION=2022` (2025 since [0008](0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md)) and `ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64`, then `FROM ${BASE_IMAGE}`.
- Each image's workflow runs a matrix `windows-version: ['2019', '2022', '2025']` with `fail-fast: false`, so one version's failure doesn't hide the others' results.
- Images are tagged by version (`:2019`, `:2022`, `:2025`). See [0005](0005-tagging-scheme-for-windows-images.md) for the full scheme.

## Consequences

- Version-specific breakage (for example `tar.exe` gaps on ltsc2019 and ltsc2022, or the `HKCU\Environment` guard needed for `setx` on ltsc2019) shows up in CI rather than for users.
- Dockerfiles must avoid features only one version has, or guard them.
- CI does three times the work, and the runner host must be able to build all three: ltsc2025 needs a host at build 26100 or later, and ltsc2019 on a newer host needs Hyper-V isolation. `windows-host-doctor` checks both.
- Adding or dropping a version (for example when ltsc2019 leaves support in January 2029) is a matrix change in every workflow plus a new ADR.

## Alternatives considered

- **Only ltsc2022.** It is simplest, but it excludes 2019 and 2025 hosts under process isolation.
- **A multi-platform manifest list per tag** (one `:latest` resolving per OS version). Docker supports it, but it needs `docker manifest create` and push steps for every release and is harder to debug. It can be added later on top of per-version tags.
- **servercore bases.** They are larger and slower to pull. They are used only as build stages when a tool needs an installer or DLLs.
