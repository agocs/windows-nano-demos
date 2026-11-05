# 0008. Images take the Windows version as an argument, default to 2025, and build as a matrix

- Status: Accepted
- Date: 2026-11-04
- Deciders: Justin Dearing
- Amends: [0002](0002-build-every-image-for-ltsc2019-ltsc2022-and-ltsc2025.md) (changes the default from 2022 to 2025)
- Related: [0009](0009-all-image-builds-use-one-reusable-workflow.md), [0011](0011-repository-conventions-are-enforced-by-tests-in-ci.md)

## Context

[0002](0002-build-every-image-for-ltsc2019-ltsc2022-and-ltsc2025.md) made every image build for ltsc2019, ltsc2022 and ltsc2025, but left the `WINDOWS_VERSION` default at 2022. That made a plain `docker build .` produce the second-newest version. Each image also wrote its own matrix, and a few didn't follow the convention exactly. ltsc2025 (10.0.26100) is the newest LTSC release and runs on current Windows 11 and Windows Server 2025 hosts. On this repo's runner host, a Windows 11 build 26300 machine, it runs with both Hyper-V and process isolation.

## Decision

Every image in this repo:

- Takes the Windows version as a build argument, defaulting to 2025. Its `Dockerfile` starts with:

  ```dockerfile
  ARG WINDOWS_VERSION=2025
  ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64
  ```

  The image stage is `FROM ${BASE_IMAGE}`. Helper stages, such as a servercore stage to copy DLLs from, may sit between those arguments and the final `FROM`, and may use `${WINDOWS_VERSION}` themselves. An image that can't run on nanoserver may default `BASE_IMAGE` to `servercore` instead, and must say why in a comment.
- Has a `build.cmd` that defaults `WINDOWS_VERSION` to 2025 when it isn't set and passes `BASE_IMAGE` through when it is.
- Is built and tested in CI for `2019`, `2022` and `2025` as a `fail-fast: false` matrix. The matrix lives in the shared workflow from [0009](0009-all-image-builds-use-one-reusable-workflow.md), not in each image's workflow.

## Consequences

- `docker build .` and `build.cmd` with no arguments give the newest version. Users on older hosts pass `--build-arg WINDOWS_VERSION=2019` or `2022`.
- Older hosts that only have the 2022 base cached pull the 2025 base on a default build.
- An image with a version-specific problem passes a base image override for that version in its workflow, as the SSH image does for 2025, rather than leaving the matrix.
- When no override makes a version work, the image's workflow may narrow the matrix with the shared workflow's `windows-versions` input. Each such image must be listed, with exactly the versions it builds, in `WINDOWS_VERSION_EXCEPTIONS` in `tests/repo_conventions.py`, must still build the default version, and must explain why in its README. The refresh workflow then never builds or publishes the excluded versions. First case: MySQL builds 2022 and 2025 only, because its restart check fails intermittently on 2019 (2026-11-05).
- [0011](0011-repository-conventions-are-enforced-by-tests-in-ci.md) tests check the `Dockerfile` and `build.cmd` defaults, so drift fails CI.

## Alternatives considered

- **Keep 2022 as the default.** It is the most widely deployed host version today, but it makes the default image older than the newest supported release for no benefit to 2025 hosts.
- **No default, so the version must be passed.** That is explicit, but it breaks the plain `docker build .` that the READMEs document.
- **A separate Dockerfile per version.** That gives full control, but triples maintenance for differences a build argument already covers.
