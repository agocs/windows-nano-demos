# 0013. The Go image has a cgo variant using llvm-mingw

- Status: Proposed
- Date: 2026-11-05
- Deciders: Justin Dearing
- Related: [Go cgo plan](../../plans/go-cgo.md), [0005](0005-tagging-scheme-for-windows-images.md), [0006](0006-publish-to-docker-hub-only-from-main-via-scheduled-workflow.md), [0008](0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md), [0009](0009-all-image-builds-use-one-reusable-workflow.md)

## Context

`windows-nano-go` sets `CGO_ENABLED=0` because nanoserver has no C compiler. Go programs that import `C`, or depend on modules that do, cannot build in it. Nanoserver has no installer support and no WoW64, so a compiler has to be a zip of x64-native tools that `tar.exe` can extract on ltsc2019, ltsc2022 and ltsc2025. The plan's experiments tried llvm-mingw, Zig, WinLibs GCC and w64devkit. Only llvm-mingw and Zig are practical, and llvm-mingw is the only one that is a plain zip, runs from `C:\Program Files` and has no first-use runtime build.

## Decision

- One Dockerfile builds both images. `ARG CGO=0` (default) gives the existing cgo-off image, with the same filesystem layers as before. `CGO=1` installs llvm-mingw (ucrt, x86_64, version pinned in the Dockerfile) in one `RUN` placed after the Go, MinGit and micro layers, so both builds share those layers. The same `RUN` deletes the i686, aarch64, armv7 and arm64ec toolchains and the debugger and IDE tools, puts the toolchain on `PATH`, sets `CC` and `CXX` with `go env -w`, and the Dockerfile sets `CGO_ENABLED=${CGO}`. `CC_TOOLCHAIN` exists so another toolchain can be added later; any value but `llvm-mingw` fails the build.
- `smoke-test.ps1` stays the single entry point ([0009](0009-all-image-builds-use-one-reusable-workflow.md)). It reads `CGO_ENABLED` from the image. With cgo on it also runs `smoke-test-cgo.ps1` and `smoke-test-cgo-sqlcmd.ps1`. With cgo off it checks that a cgo build fails.
- CI builds and tests the cgo variant for the newest Go only, on all three Windows versions, as one extra `include` entry in the go-container matrix.
- Tags: the variant tag is `<go>-cgo-<win>`, locally and on Docker Hub, with the [0005](0005-tagging-scheme-for-windows-images.md) suffixes after the Windows version. The scheme for variants is defined by the amended ADR 0005, not here.

## Consequences

- The cgo image is much larger than the plain one (see the plan's implementation notes for the measured size), and its build takes 10 to 15 minutes longer while the zip extracts. A separate layer means that cost is paid only when the toolchain pin changes.
- Publishing is not wired up yet. `build-windows-image.yml` publishes tags that carry only the Windows version, so publishing the cgo leg through it would overwrite the plain image's tags. `image-refresh.yml` and `scripts/refresh_matrix.py` build only the default variant and never pass `CGO`, so a refresh publishes only the plain image. Until the shared workflow gains variant-aware tags, the cgo leg is build and test only. Once it does, the go-container entry gets `tag-prefix: 1.27.3-cgo`.
- llvm-mingw releases often. The pin must be bumped separately from base-image refreshes ([0007](0007-separate-tool-version-bumps-from-base-image-refreshes.md)).
- llvm-mingw is Apache-2.0 with LLVM exceptions plus mingw-w64 (permissive). Programs built with it carry no GPL terms.
- Labels that record the toolchain (planned in the plan) are not part of this change.

## Alternatives considered

- **A separate Dockerfile or image folder for cgo.** It would duplicate the Go, MinGit and micro steps and drift. One Dockerfile with a build argument shares the cached layers.
- **cgo on in the default image.** It adds hundreds of megabytes for every user who does not need it.
- **Zig as the compiler.** Half the size, but pre-1.0, `CC` needs spaces and the first use of each target is slow. Documented as an alternative.
- **WinLibs GCC or w64devkit.** Needs a space-free install path and a 7z that only ltsc2025's tar reads, or a servercore stage. Larger, and adds GPL components to the image.
