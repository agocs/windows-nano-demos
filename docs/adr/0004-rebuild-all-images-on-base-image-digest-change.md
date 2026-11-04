# 0004. Rebuild all images on base-image digest change

- Status: Proposed
- Date: 2026-11-04
- Deciders: Justin Dearing
- Related: [Patch Tuesday plan](../../plans/patch-tuesday-image-refresh.md), [0005](0005-tagging-scheme-for-windows-images.md), [0006](0006-publish-to-docker-hub-only-from-main-via-scheduled-workflow.md)

## Context

Microsoft ships security fixes for Windows on Patch Tuesday (the second Tuesday of the month), and MCR republishes `nanoserver:ltsc2019|ltsc2022|ltsc2025` with a new OS build revision, usually the same day and sometimes out of band. Our images bake in the base at build time, so a published image stays unpatched until it is rebuilt. Today nothing rebuilds them.

## Decision

We will detect base changes by digest and rebuild every image for each Windows version whose base changed:

- A scheduled detection job (twice daily, on `ubuntu-latest`) reads the `windows/amd64` manifest digest and `os.version` of each `mcr.microsoft.com/windows/nanoserver:ltsc<ver>-amd64` tag with `docker manifest inspect -v`.
- It compares them with the `org.opencontainers.image.base.digest` label on each published `zippy1981/windows-nano-<x>:<ver>`. A mismatch, or a missing image, schedules a rebuild of that image and version. There is no separate state file. The published images are the state.
- The build pins the detected digest (`--build-arg BASE_IMAGE=...:ltsc<ver>-amd64@sha256:<digest>`) and records it in the label, so what is built is exactly what was detected.
- All images for that version are rebuilt, whether or not their own layers would change.

## Consequences

- Published images are at most about a day behind MCR, with no human in the loop.
- Detection is stateless and self-healing: a failed or skipped run is retried by the next one, because the published label still differs.
- About six builds a month (two images times three versions) on the runner host, plus layer growth. Cleanup is handled separately (see the plan).
- Polling daily rather than on one scheduled Wednesday also covers out-of-band releases. GitHub cron can't express "the Wednesday after the second Tuesday", because it ORs day-of-month and day-of-week.
- Images with a servercore build stage (for VC++ DLLs) also depend on `mcr.microsoft.com/windows/servercore:ltsc<ver>-amd64`. Those images carry a second label, `com.zippy1981.servercore.digest`, and detection treats a change in either digest as a base change. MCR usually updates both on the same day. If servercore lags, the image is rebuilt again when it lands.

## Alternatives considered

- **A fixed monthly cron.** Simple, but it misses late or out-of-band releases and rebuilds even when nothing changed.
- **A committed `base-images.json` state file updated by the workflow.** It needs a bot with push rights to `main`, creates noise commits, and can drift from what is actually published.
- **Dependabot or Renovate on the `FROM` line.** Our `FROM` uses a build argument and a moving tag, which they don't track by digest without pinning digests in Dockerfiles. Pinning would mean a PR per version per month.
- **Rebuild only images whose content would change.** Every image layers on the base, so this is always all of them.
