# 0005. Tagging scheme for Windows images

- Status: Proposed
- Date: 2026-11-04
- Deciders: Justin Dearing
- Related: [Patch Tuesday plan](../../plans/patch-tuesday-image-refresh.md), [0002](0002-build-every-image-for-ltsc2019-ltsc2022-and-ltsc2025.md), [0004](0004-rebuild-all-images-on-base-image-digest-change.md)

## Context

Images are rebuilt every month when the base changes ([0004](0004-rebuild-all-images-on-base-image-digest-change.md)) and whenever a tool version changes. Users need a tag that always gives the latest, a way to pin to a known OS patch level, and an immutable reference for reproducing a bug. Today images are tagged only `windows-nano-<x>:<ver>` locally and `zippy1981/windows-nano-<x>:<ver>` on Docker Hub.

## Decision

Every published build of `zippy1981/windows-nano-<x>` for Windows version `<ver>` (`2019`, `2022`, or `2025`) gets four tags:

| Tag | Example | Moves? | Use |
| --- | --- | --- | --- |
| `:<ver>` | `:2022` | Every build | Latest for that Windows version |
| `:<ver>-<os-build>` | `:2022-10.0.20348.2849` | Within one OS build, when tools change | Pin to a Windows patch level |
| `:<ver>-<YYYY-MM>` | `:2022-2026-11` | Within the month (UTC build date) | Pin to a patch month |
| `:<ver>-<os-build>-<git-sha7>` | `:2022-10.0.20348.2849-d46a4a6` | Never | Reproducible reference |

`<os-build>` comes from the base image's `os.version`. `<git-sha7>` is the commit the image was built from. Every image also carries the OCI labels `org.opencontainers.image.base.name`, `.base.digest`, `.revision`, `.created`, and `.source`.

Local and CI builds keep `windows-nano-<x>:<ver>`, and CI test images use `windows-nano-<x>:<ver>-<github.sha>` so parallel runs don't collide. There is no `:latest`, because no single Windows version suits every host.

## Consequences

- Users choose their stability: `:2022` for automatic patches, `:2022-10.0.20348.2849` to match a host's patch level, or the SHA tag to freeze.
- Four pushes per leg. The layers are shared, so only the first push uploads.
- Old immutable tags pile up on Docker Hub. A retention policy can be added later. Local host retention is handled by the cleanup script.
- The image READMEs must document the scheme.

## Amendment: variant images (2026-11-05)

Some images are published in several variants of the same Windows version, such as the Go image with one variant per Go release, and a cgo variant to come. Each variant has a **tag prefix**, and every tag above is prefixed with it:

- `windows-nano-go:1.26.10-2025`, `:1.26.10-2025-<os-build>`, `:1.26.10-2025-YYYY-MM` and `:1.26.10-2025-<os-build>-<sha7>`
- `windows-nano-go:1.27.3-cgo-2025` and so on, for the cgo variant

**Exactly one variant per image is its default**, the newest Go with cgo off for the Go image. The default variant also publishes the plain tags above (`:2025` …), so `docker pull zippy1981/windows-nano-go:2025` keeps working.

How it works:

- An image declares its variants as `strategy.matrix.include` entries in its workflow. Each entry passes `build-args`, `variant` (the CI tag), `tag-prefix` and `also-plain-tags` to the shared workflow.
- `scripts/refresh_matrix.py` expands those entries into one leg per variant and reads each variant's labels from its own `:<prefix>-<ver>` tag. It refuses an image whose variants repeat a prefix, leave one empty, or don't have exactly one `also-plain-tags`.
- The published image is labelled `org.opencontainers.image.version=<prefix>`.

Any image can use this the same way. An image with a single variant passes neither input and keeps the plain tags.

## Alternatives considered

- **KB-number tags (`:2022-KB5044281`)**, as MCR does. They are meaningful to admins, but the KB number isn't in the image metadata and has to be scraped from the MCR tags list. The OS build is in the image.
- **SemVer for our own releases.** These images have no release cadence of their own. The base and the tool versions define them.
- **Only `:<ver>`.** Users can't pin, and a broken monthly build would have no tag to roll back to.
- **`:latest` aliasing ltsc2022.** It would fail confusingly on 2019 and 2025 hosts under process isolation.
