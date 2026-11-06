# 0012. Images live in a directory for their base image

- Status: Accepted
- Date: 2026-11-05
- Deciders: Justin Dearing
- Related: [0008](0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md), [0011](0011-repository-conventions-are-enforced-by-tests-in-ci.md), issue #25

## Context

Every image lived in a top-level `nano-server-*` folder and was published as `windows-nano-*`, including Far Manager, which is built on Server Core because Far needs desktop DLLs that Nano Server lacks. The names said Nano Server where the image wasn't, and the repo root kept growing with every image.

## Decision

- An image lives in the directory for the base of its final stage, which is the default of its `BASE_IMAGE` argument (ADR 0008):
  - `nano-server/nano-server-<name>/` for `mcr.microsoft.com/windows/nanoserver`
  - `server-core/server-core-<name>/` for `mcr.microsoft.com/windows/servercore`
- It is published as `zippy1981/windows-nano-<name>` or `zippy1981/windows-servercore-<name>` to match.
- Build stages don't count. PHP and MySQL copy the Visual C++ runtime from a Server Core stage but ship on Nano Server, so they stay under `nano-server/`.
- A per-version override doesn't count either. SSH uses Server Core on ltsc2025 only, through `base-image-overrides`, and stays under `nano-server/`.
- `tests/test_image_layout.py` enforces this (ADR 0011). It checks that no image folder is left in the repo root, that each folder is named after its directory, that the directory matches the `BASE_IMAGE` default, and that the caller workflow publishes the matching name.

## Consequences

- An image's path and Docker Hub name say what it's built on.
- Far moved to `server-core/server-core-far` and is now published as `zippy1981/windows-servercore-far`. Tags already pushed to `zippy1981/windows-nano-far` stay where they are, but nothing updates them.
- Branches that add or change images under the old paths (#16, #21, #22, #31 and others) have to move their folders when they rebase. Git usually follows the renames of files they only edit.
