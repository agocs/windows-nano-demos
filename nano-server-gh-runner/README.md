# GitHub Actions runner on Windows nano server

A self-hosted [GitHub Actions runner](https://github.com/actions/runner) in a nano server container. It has PowerShell 7, MinGit and the docker CLI. There is no docker daemon in the image. Jobs build and run containers on the host's daemon through its named pipe.

This repo's workflows run on it with `runs-on: [self-hosted, windows, docker]`.

## Building

```cmd
build.cmd
```

## Running

The host's docker pipe can only be mounted into a process-isolated container, so the image's Windows version has to be compatible with the host. `ltsc2025`, the default, and `ltsc2022` both work on Windows 11 build 26100 and later. `ltsc2022` also works on Windows Server 2022. `ltsc2019` doesn't support process isolation on newer hosts.

`run-runner.ps1` gets a registration token with the `gh` CLI and starts the container:

```pwsh
./run-runner.ps1 -Repo zippy1981/windows-nano-demos
```

The equivalent `docker run` is:

```pwsh
docker run -d --name runner --restart unless-stopped --isolation=process `
    -v '\\.\pipe\docker_engine:\\.\pipe\docker_engine' `
    -e RUNNER_URL=https://github.com/zippy1981/windows-nano-demos `
    -e RUNNER_TOKEN=<registration token> `
    windows-nano-gh-runner:2025
```

Optional environment variables:

- `RUNNER_NAME`: defaults to the container's host name
- `RUNNER_LABELS`: extra labels, defaults to `nanoserver,docker`. GitHub adds `self-hosted`, `Windows` and `X64` itself.

The runner registers on first start. The registration stays in the container, so `docker restart` reuses it without a new token. `docker rm` loses it. Run `run-runner.ps1` again to register a fresh one (`--replace` reuses the same name).

## Security

Access to the docker pipe is equivalent to administrator access on the host. Any workflow that runs on this runner can take over the machine. The workflows in this repo skip pull requests from forks. Keep "Require approval for all outside collaborators" turned on in the repository's Actions settings.

## Limitations

- `actions/setup-*` actions work, because PowerShell is present for their archive extraction.
- Job containers (`container:` in a workflow) and service containers aren't supported on Windows runners. Call `docker` from steps instead.
- The job workspace is inside the runner container, so `docker run -v <workspace>:...` paths don't exist on the host. Bake files into images, or use `docker cp`.
