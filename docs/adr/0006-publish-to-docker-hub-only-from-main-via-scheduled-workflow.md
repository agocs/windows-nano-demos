# 0006. Publish to Docker Hub only from main via scheduled workflow

- Status: Proposed
- Date: 2026-11-04
- Deciders: Justin Dearing
- Related: [Patch Tuesday plan](../../plans/patch-tuesday-image-refresh.md), [0003](0003-self-hosted-nanoserver-runners-using-host-docker-daemon-via-named-pipe.md), [`.claude/agents/windows-image-publisher.md`](../../.claude/agents/windows-image-publisher.md)

## Context

Images are pushed to Docker Hub by hand today (`windows-image-publisher`). Automated refreshes ([0004](0004-rebuild-all-images-on-base-image-digest-change.md)) need CI to push, which means Docker Hub credentials on self-hosted runners whose containers persist between jobs and that have host docker access ([0003](0003-self-hosted-nanoserver-runners-using-host-docker-daemon-via-named-pipe.md)).

## Decision

We will publish from exactly one place: the image refresh workflow (`.github/workflows/image-refresh.yml`), when it runs on `main`, either on its schedule or by `workflow_dispatch`.

- `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a scoped Docker Hub access token, not a password) live in a `dockerhub` GitHub environment that only `main` can use.
- Per-image workflows on push and pull request build and smoke-test only. They never log in.
- A leg is pushed only after its smoke test passes, in the same job on the same daemon, so the pushed image is the tested image.
- The push step logs in with `--password-stdin` into a per-job `DOCKER_CONFIG` directory, then runs `docker logout` and deletes that directory in an `if: always()` step.
- Merged source changes (tool bumps) are published by the next refresh run, which rebuilds when the folder's latest commit differs from the published image's `org.opencontainers.image.revision` label. Dispatch the workflow to publish sooner.

## Consequences

- Nothing reaches Docker Hub without being on `main` and passing tests. Branches and fork PRs can't read the token.
- Credentials don't linger in persistent runner containers.
- A merged change can take up to about 12 hours to publish unless the workflow is dispatched.
- `windows-image-publisher` remains for manual pushes from a developer machine, and should be rare.

## Alternatives considered

- **Push from every per-image workflow on `main`.** That spreads publishing and secrets across many workflows, and lets a tool bump and a base refresh race to push the same tags.
- **Push on tags or GitHub releases.** These images have no release cadence of their own, and monthly manual tagging defeats the automation.
- **Repository-level secrets.** Any workflow on any branch by a collaborator could read them. An environment restricted to `main` is narrower.
