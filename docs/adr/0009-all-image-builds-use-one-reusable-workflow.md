# 0009. All image builds use one reusable workflow

- Status: Accepted
- Date: 2026-11-04
- Deciders: Justin Dearing
- Related: [0003](0003-self-hosted-nanoserver-runners-using-host-docker-daemon-via-named-pipe.md), [0008](0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md), [0011](0011-repository-conventions-are-enforced-by-tests-in-ci.md)

## Context

Each image had its own copy of the same job: the fork guard, the self-hosted runner labels, the version matrix, checkout, `docker build`, a smoke test and cleanup. The copies drifted. Some had `--memory 4g` and `timeout-minutes: 60` and some didn't, and those that didn't hung for hours under Hyper-V's default 1 GB memory limit. A fix had to be made in every file.

## Decision

`.github/workflows/build-windows-image.yml` is a reusable workflow (`on: workflow_call`). It owns the whole build-and-test job:

- the fork guard and `runs-on: [self-hosted, windows, docker]`
- the `fail-fast: false` matrix over `windows-version: ['2019', '2022', '2025']`
- `timeout-minutes`, `docker build --memory 4g` and the version build argument
- running the image's smoke test, reporting the image size, and cleaning up containers and the image whether or not the job succeeds

Each image has a small caller workflow. It defines the triggers, with path filters that include the image folder, the caller itself and the reusable workflow, and one job that `uses: ./.github/workflows/build-windows-image.yml` with:

- `context`: the image folder
- `image`: the image name
- `base-image-overrides` (optional): a JSON map from Windows version to base image, for a version that needs a different base

Each image's smoke test is a PowerShell script at `<image folder>/smoke-test.ps1` that takes `-Image <tag>` and throws on failure. It runs on the runner and calls `docker run`, so it can start several containers, as the SSH test does.

## Consequences

- A CI fix, such as a new build flag, a timeout or a cleanup step, is made once and applies to every image.
- Smoke tests become scripts a developer can run locally against an image they built: `./nano-server-php/smoke-test.ps1 -Image windows-nano-php:2025`.
- Check names change to `build / build-and-test (<version>)`.
- An image that really needs a different job shape must change the reusable workflow through an input, or record an exception in a new ADR.

## Alternatives considered

- **A composite action.** It can share steps but not `runs-on`, the matrix or the job-level guard, which are the parts that drifted.
- **One workflow that builds every image.** That needs fewer files, but it reruns every image on any change and gives a single wide matrix that is hard to read.
- **Keep the copies and lint them.** The [0011](0011-repository-conventions-are-enforced-by-tests-in-ci.md) tests would catch drift, but every fix would still have to be made in every file.
