# Working in this repo

Windows container images (nanoserver, with servercore where needed), built and tested on self-hosted Windows runners, published to Docker Hub as `zippy1981/<image>`. Read [DEVELOPER.md](DEVELOPER.md) before working on an image, and the [ADRs](docs/adr/README.md) before changing CI or conventions.

This file is the Muse Code counterpart to [CLAUDE.md](CLAUDE.md), which serves the same purpose for Claude Code. The two files carry the same rules. When a rule changes, change both files in the same commit.

## Muse Code in this repo

- **Rules:** Muse Code reads this file as project rules when it runs in this directory. It does not read `CLAUDE.md` or `.claude/settings.json`.
- **Skills:** the project skills under `.claude/skills/` and `.agents/skills/` are discovered and load as Muse Code project skills as they are. Do not copy them into a second folder to make them work. `github-issues` exists in both folders with identical content; Muse Code uses the `.agents/skills/` copy.
- **Agents:** `.claude/agents/*.md` are Claude Code subagent definitions. Muse Code does not load them as agent definitions. Treat each file as a role playbook: follow its procedure yourself, or hand it to a built-in subagent as part of its task. Model names in those files (haiku, sonnet, opus) do not map to Muse Code models; use the cheapest model that fits the role, as `.claude/agents/README.md` intends.
- **Settings:** `.claude/settings.json` sets `UV_PYTHON=3.14` and `UV_PYTHON_PREFERENCE=only-managed` for Claude Code. Muse Code ignores that file, so set both variables in your shell environment before running `uv` on the Windows host.
- **Hosts:** Muse Code also runs on non-Windows hosts, where Windows containers cannot be built or run. From such a host, implement in a worktree, push the branch, and let the self-hosted Windows CI runners do every build and smoke test. Accept no change on local evidence alone.

## Environment (Windows host)

- **Python:** always through uv (ADR 0010): `uv run pytest`, `uv run python scripts/<x>.py`. Set `UV_PYTHON=3.14` and `UV_PYTHON_PREFERENCE=only-managed` in the environment first (see above). Without them uv picks 3.15, which has no PyYAML wheel, and fails building it. If `uv` isn't on PATH, it's at `%LOCALAPPDATA%\Microsoft\WinGet\Packages\astral-sh.uv_*\uv.exe`. `python3` on this host is only the Microsoft Store stub.
- **Before committing:** run `uv run pre-commit run --all-files`, which runs ruff format and check, markdownlint and pytest. Never weaken a test to make it pass. Coverage of `scripts/` must stay at 95% or more: a new script or branch comes with its tests. Parametrize tests over images, workflows and badges rather than looping inside one test.
- **Line endings:** Markdown, YAML, Python, TOML, JSON and Dockerfiles are LF. `.cmd`, `.bat` and `.ps1` are CRLF. In an older CRLF working copy, `sed` and `perl` edits anchored at line ends silently miss, so use the Edit tool or re-check out.
- **PowerShell quirks:** don't name a variable `$args`. Write `${name}:` when a colon follows a variable in a string. A function returns everything it outputs, so send command output to `Out-Host` in helpers.

## Images and CI (ADRs 0008, 0009, 0011)

- **Dockerfiles** start with `ARG WINDOWS_VERSION=2025` and `ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64`, and the last stage is `FROM ${BASE_IMAGE}`. Get DLLs from a servercore build stage, never from the host.
- **Builds:** `docker build --memory 4g`, because Hyper-V's 1 GB default hangs builds.
- **Workflows:** each image has a small workflow that calls `.github/workflows/build-windows-image.yml`, plus a `<folder>/smoke-test.ps1 -Image <tag>`. Variants use matrix `include` entries with `tag-prefix` (ADR 0005). Only `image-refresh.yml` publishes, and only from `main`.
- **Self-hosted runners** (`[self-hosted, windows, docker]`) are nanoserver containers on the host's Docker pipe. Jobs need the fork guard and a timeout. Never bind-mount the workspace into job containers; use `docker cp`.
- `tests/` enforces all of this. Run it after touching workflows, Dockerfiles or `build.cmd`.

## Shared host safety

- **The Docker daemon is shared** with five runners and other sessions. Never `docker ... prune`. Name what you create with a unique prefix, and clean up with `scripts/Remove-DockerArtifacts.ps1 -Prefix <p>` (the `safe-docker-cleanup` skill). Never touch `DEARING-HP-Z-nano*` containers.
- **Never install services or scheduled tasks**, change power, firewall, DNS, hosts or certificate stores, or touch secrets, without asking.
- **Long builds** run in the background, and you wait for the notification.

## GitHub workflow

- **Branch from `origin/main` in a worktree** (`git worktree add ../wt-<name> -b <branch> origin/main`). The main checkout belongs to the user.
- **Commits** end with the attribution trailers the session gives you. PR bodies end with the attribution line the session gives you.
- **CI status:** use the `repo-status` and `ci-triage` skills, or the `ci-watcher` agent playbook, instead of polling or reading whole logs.
- **Conflicts, stacks and merges:** follow the `pr-shepherd` skill. Merge only when the user asked and every check on the head commit passed. Never use `--admin`.
- **Parallel agents:** at most about 3 at once. Use a cheap model for watching and fixing, a mid model for implementing, and the strongest model for design and security review ([.claude/agents/README.md](.claude/agents/README.md)).
