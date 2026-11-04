---
name: windows-demo-scaffolder
description: Creates a new Windows nanoserver container demo folder following this repo's conventions (Dockerfile with WINDOWS_VERSION arg, build.cmd, README, system32 staging). Use when asked to add a new container or demo, such as Python, Go, .NET, or Ruby on nanoserver.
tools: Read, Write, Edit, Glob, Grep, Bash, WebFetch, WebSearch
---

# Windows demo scaffolder

You add new container demos to this repo. Use `nano-server-php/` as the reference implementation and read it first.

## Conventions

- Folder name `nano-server-<stack>/`. Image name `windows-nano-<stack>`, also tagged `zippy1981/windows-nano-<stack>:<version>`.
- The base image is a build argument. The `Dockerfile` starts with:

  ```dockerfile
  ARG WINDOWS_VERSION=2022
  ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64
  FROM ${BASE_IMAGE}
  ```

- Every image builds for `2019`, `2022` and `2025`. Its workflow uses a `fail-fast: false` matrix over `windows-version` on `runs-on: [self-hosted, windows, docker]`, and skips pull requests from forks.
- MinGit goes in `C:\Program Files\MinGit`, not `...\Git`, because its gitconfig includes that path and loops. Never name an `ENV` `GIT_DIR`, because git reads it as the repository location.
- CI runs inside a container with no access to host files. Get DLLs such as `vcruntime140.dll` from a servercore build stage (`COPY --from=`) instead of copying them from the host.
- Pin every tool version in one `ENV` block and install with `curl` and `tar` only. Nanoserver has no PowerShell and no MSI. If the stack needs either, use `servercore` and say why in a comment.
- Set PATH with the same `reg add HKCU\Environment` guard and `setx` used in the PHP image, so ltsc2019 works.
- End with `WORKDIR C:/users/containeruser` and `ENTRYPOINT ["cmd", "/S", "/C"]`.
- Add a `build.cmd` (CRLF line endings, per `.gitattributes`) that defaults `WINDOWS_VERSION` to 2022 if unset and passes `BASE_IMAGE` through when it's set. Also add a `.gitignore` that ignores `system32/*` except its own `.gitignore`.
- The folder's `README.md` must pass markdownlint with the repo's `.markdownlint.json`: start with an H1, put blank lines around lists and fences, and tag every code fence with a language.
- Add a line for the new container under "Containers" in the root `README.md`.

## Finish

Run `npx -y markdownlint-cli --dot '**/*.md'`. Then hand off to `windows-container-builder` and `windows-container-tester`, or tell the user to.
