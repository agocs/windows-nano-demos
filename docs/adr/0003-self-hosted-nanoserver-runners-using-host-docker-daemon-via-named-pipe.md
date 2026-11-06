# 0003. Self-hosted nanoserver runners using the host docker daemon via named pipe

- Status: Accepted
- Date: 2026-11-04
- Deciders: Justin Dearing
- Related: [`nano-server-gh-runner/`](../../nano-server/nano-server-gh-runner/README.md), [`.github/workflows/gh-runner-container.yml`](../../.github/workflows/gh-runner-container.yml), [0002](0002-build-every-image-for-ltsc2019-ltsc2022-and-ltsc2025.md)

## Context

GitHub-hosted Windows runners can build Windows containers, but only for the runner's own OS version, slowly, and without layer caching between runs. Building three Windows versions for every image needs a host that can build all three and keeps base layers cached. The repo is itself a demo of nanoserver containers, so running the CI runner in one is in scope.

## Decision

We will run CI image jobs on self-hosted GitHub Actions runners that are themselves nanoserver containers (`nano-server-gh-runner/`), with PowerShell 7, MinGit, and the docker CLI, but no daemon. Each runner container is started with `--isolation=process` and the host's `\\.\pipe\docker_engine` mounted, so `docker build` and `docker run` in a job use the host's daemon. Jobs target `runs-on: [self-hosted, windows, docker]`.

Because the pipe gives full control of the host, every job on these runners carries this guard, and no workflow uses `pull_request_target`:

```yaml
if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
```

The repository also keeps "Require approval for all outside collaborators" on.

## Consequences

- Builds reuse the host's cached base layers, and one host builds all three versions.
- **Security:** access to the docker pipe is equivalent to administrator on the host. Any code that runs in a job can take over the machine. The fork guard, approval setting, and environment-scoped secrets are what stop untrusted code reaching it. Any workflow change that alters who can trigger a self-hosted job needs `cicd-engineer` review.
- Pipe mounts need process isolation, so the runner image's Windows version must be compatible with the host.
- The job workspace is inside the runner container. `docker run -v <workspace>:...` paths don't exist on the host, so tests are baked into images or passed with `-EncodedCommand`.
- Job containers and service containers (`container:`, `services:`) aren't available on Windows runners.
- Runner containers persist between jobs (registration lives in the container), so jobs must clean up their images and any `docker login` state. The runner image needs its own monthly rebuild, and runner containers must be recreated from it (see the Patch Tuesday plan).
- Lint and other OS-independent jobs stay on `ubuntu-latest`.

## Alternatives considered

- **GitHub-hosted `windows-2019`/`windows-2022`/`windows-2025` runners.** No host to maintain, but no layer cache, each runner builds only its own version under process isolation, and builds are slow.
- **Runner installed directly on the host.** Simpler, but a job could then leave anything on the host. It would also miss the point of demonstrating a nanoserver runner.
- **Docker-in-docker.** Windows containers can't run a nested docker daemon.
- **Ephemeral runners (`--ephemeral`) recreated per job.** This gives better isolation between jobs and is worth revisiting. It isn't adopted yet because it needs a host-side loop that fetches a registration token and starts a fresh container after every job.
