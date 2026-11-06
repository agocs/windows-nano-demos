---
name: dockerfile-docs
description: How every Dockerfile in this repo documents itself - a header that says what the image is and how to build it, and a comment above each build argument that says what it does and how to set it. Use when writing or changing a Dockerfile, adding an ARG, or reviewing Dockerfile comments. tests/test_dockerfile_docs.py enforces it.
---

# Dockerfile documentation

Each Dockerfile explains itself, so you don't need the README to build it. `tests/test_dockerfile_docs.py` checks every image under `nano-server/` and `server-core/`, with one test per image and per build argument.

## The header

The file starts with a comment block, before the first `ARG`:

```dockerfile
# windows-nano-go: Go, MinGit and the micro editor on Nano Server. CI builds the three newest Go releases.
#
# (optional) Anything a builder must know first, such as a base-image exception for one Windows version.
#
# Build from this folder (build.cmd does the same, and also tags zippy1981/windows-nano-go):
#   docker build --memory 4g --build-arg WINDOWS_VERSION=2022 --build-arg GO_VERSION=1.26.10 -t windows-nano-go:2022 .
# Each build argument is described where it is declared below.
```

- **First line:** `# <published image name>: <what the image is>`. Write one sentence that a person choosing an image would understand. It should say what's installed, not how it's built.
- **Build example:** include a `docker build` line with at least one `--build-arg`, and `--memory 4g` (Hyper-V's 1 GB default hangs builds).
- **No `key=value` on the first line.** Docker would read `# key=value` there as a parser directive.

## Build arguments

Put a comment directly above the first `ARG` of each name, with no blank line between them. The comment says what the argument is, its default if that isn't obvious, and how to set it with `--build-arg NAME=<example>`:

```dockerfile
# Windows Server LTSC version to build for: 2019, 2022 or 2025 (the default). Set with --build-arg WINDOWS_VERSION=2022.
ARG WINDOWS_VERSION=2025
# The image the final stage is built on. Defaults to Nano Server for WINDOWS_VERSION; CI pins it to a digest.
# Set with --build-arg BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc2022-amd64.
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64
```

- Use the standard `WINDOWS_VERSION` and `BASE_IMAGE` wording above. For Server Core images, say Server Core and use the servercore example.
- An explanation that belongs with the argument, such as why Far needs Server Core, goes in the same comment block, ending with the `Set with` line.
- A repeated `ARG NAME` inside a later stage only brings the value into that stage, so it needs no comment.
- Tool versions pinned with `ENV`, not `ARG`, aren't build arguments. Comment them where it helps, but the test doesn't require it.

## Who writes it

`container-author`, `windows-demo-scaffolder` and `windows-deps-updater` write the Dockerfile and a first draft of these comments. They then hand the file to `markdown-reviewer`, which checks the wording and this format. It starts `markdown-fixer` to apply the changes, then runs `uv run pytest -q tests/test_dockerfile_docs.py`.

## On Docker Hub

The documentation is published with the image. `scripts/Publish-DockerHubDocs.ps1` turns the header's description into the Docker Hub short description, which allows at most 100 characters. It turns the image's `README.md` into the overview, with relative links rewritten to GitHub URLs. The shared workflow:

- runs the script with `-WhatIf` on every build, pull requests included, so a description that is too long or a missing README fails early
- runs it for real after a push to `main`
- sets the `org.opencontainers.image.description` and `documentation` labels on the image

To preview an overview locally, run `./scripts/Publish-DockerHubDocs.ps1 -Context <folder> -Repository zippy1981/<image> -WhatIf -PreviewPath overview.md`.
