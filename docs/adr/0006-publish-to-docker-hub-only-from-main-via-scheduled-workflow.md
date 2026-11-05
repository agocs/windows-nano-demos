# 0006. Publish to Docker Hub only from main via the image refresh workflow

- Status: Proposed
- Date: 2026-11-04
- Deciders: Justin Dearing
- Related: [Patch Tuesday plan](../../plans/patch-tuesday-image-refresh.md), [0003](0003-self-hosted-nanoserver-runners-using-host-docker-daemon-via-named-pipe.md), [`.claude/agents/windows-image-publisher.md`](../../.claude/agents/windows-image-publisher.md)

## Context

Images are pushed to Docker Hub by hand today (`windows-image-publisher`). Automated refreshes ([0004](0004-rebuild-all-images-on-base-image-digest-change.md)) need CI to push, which means Docker Hub credentials on self-hosted runners whose containers persist between jobs and that have host docker access ([0003](0003-self-hosted-nanoserver-runners-using-host-docker-daemon-via-named-pipe.md)).

## Decision

We will publish from exactly one place: the image refresh workflow (`.github/workflows/image-refresh.yml`), when it runs on `main`. It runs on every push to `main`, on its twice-daily schedule (which picks up Patch Tuesday base images), and by `workflow_dispatch`.

- `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a scoped Docker Hub access token, not a password) live in the `Docker Hub zippy1981` GitHub environment, which only `main` can deploy to.
- Per-image workflows on push and pull request build and smoke-test only. They never log in.
- A leg is pushed only after its smoke test passes, in the same job on the same daemon, so the pushed image is the tested image.
- The push step logs in with `--password-stdin` into a per-job `DOCKER_CONFIG` directory, then runs `docker logout` and deletes that directory in an `if: always()` step.
- A merge to `main` publishes the images it changed in that push's refresh run. Detection reports an image as `source-changed` when its folder has commits after the published image's `org.opencontainers.image.revision` label, and rebuilds only those. Images the merge didn't touch aren't rebuilt.
- Runs never overlap. The workflow's concurrency group queues a new run behind the running one instead of cancelling it.

## Consequences

- Nothing reaches Docker Hub without being on `main` and passing tests. Branches and fork PRs can't read the token.
- Credentials don't linger in persistent runner containers.
- A merged change is published as soon as its refresh run finishes. Base image updates are published within about 12 hours of Microsoft releasing them.
- A changed image folder builds twice after a merge: once in its own image workflow (build and test only) and once in the refresh run (build, test and publish). The shared layer cache makes the second build cheap.
- `windows-image-publisher` remains for manual pushes from a developer machine, and should be rare.

## Amendments

- 2026-11-05: the refresh workflow also runs on every push to `main`, so merges publish right away instead of waiting for the next scheduled run (requested by the repository owner). The secrets environment is now named `Docker Hub zippy1981`.

## Alternatives considered

- **Push from every per-image workflow on `main`.** That spreads publishing and secrets across many workflows, and lets a tool bump and a base refresh race to push the same tags.
- **Push on tags or GitHub releases.** These images have no release cadence of their own, and monthly manual tagging defeats the automation.
- **Repository-level secrets.** Any workflow on any branch by a collaborator could read them. An environment restricted to `main` is narrower.
