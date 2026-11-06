# Go image with cgo on nanoserver

## Goal

`windows-nano-go` gets a cgo-capable variant that runs on nanoserver (not servercore) for ltsc2019, ltsc2022 and ltsc2025, with a pinned C toolchain, its own tags, labels that say which toolchain it has, and smoke tests that prove cgo works. The existing cgo-off image stays as it is.

## Context

- `nano-server-go/Dockerfile` sets `CGO_ENABLED=0` because nanoserver has no C compiler. It takes `GO_VERSION` (CI builds 1.27.3, 1.26.10 and 1.25.14) and `WINDOWS_VERSION`. `GOTOOLCHAIN=local`.
- Nanoserver has `curl.exe` and `tar.exe` (bsdtar) but no installer support and no WoW64, so only x64-native tools in zip form can be installed. The tar in ltsc2022 reports `LZMA codec is unsupported` for 7z files. The tar in ltsc2025 does read a 7z.
- Conventions: ADR [0008](../docs/adr/0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md) (Windows version argument, 2025 default), [0009](../docs/adr/0009-all-image-builds-use-one-reusable-workflow.md) (one shared workflow, `<image>/smoke-test.ps1 -Image <tag>`), [0011](../docs/adr/0011-repository-conventions-are-enforced-by-tests-in-ci.md) (convention tests), [0005](../docs/adr/0005-tagging-scheme-for-windows-images.md) (tags).
- PR #28's lesson: labels added in the build step change the image ID on every run and break layer caching for images built `FROM` it. `build-windows-image.yml` adds labels only in the publish step, by building `FROM <image>` with `--label`.
- Experiments ran on this repo's Windows 11 host (Hyper-V isolation, `docker build --memory 4g`). The prototype Dockerfiles and the runner script were in `experiments/go-cgo/`, never wired into CI, and were removed once the llvm-mingw variant landed in `nano-server/nano-server-go` (they are in this branch's history). They layer the toolchain on a built `windows-nano-go` image (Go 1.27.3).

## Experiment results

All three toolchains below were downloaded inside the nanoserver build and run there. The test is `cc --version`, then a Go program that calls a C function through `import "C"` and prints `cgo says 42`, where 42 is computed in C. "Size" is the final image size, and the delta is over the matching cgo-off image (852 MB, 672 MB and 630 MB for 2025, 2022 and 2019). Build times were taken while other builds ran on the host, so compare them only loosely.

| Toolchain (pinned version, download) | 2025 | 2022 | 2019 | Size delta | Build time (2025 / 2022 / 2019) |
| --- | --- | --- | --- | --- | --- |
| llvm-mingw `20261104` ucrt x86_64 zip (191 MB), clang 23.1.5 | pass | pass | pass | +755 MB / +758 MB / +756 MB | 911 s / 637 s / 636 s. The hello build took 171 s, 79 s and 80 s |
| Zig `0.17.1` x86_64-windows zip (100 MB), `zig cc -target x86_64-windows-gnu`, clang 22.1.8 | pass | pass | pass | +382 MB / +384 MB / +382 MB | 1282 s / 2622 s / 2611 s. The hello build took 463 s, 941 s and 942 s (slower, partly host contention, partly zig building its libc runtime on first use) |
| WinLibs GCC `16.2.0` ucrt posix seh x86_64 7z (112 MB; the zip is 276 MB), r3 | fail, then pass when moved to `C:\mingw64` | not run | not run | +971 MB (2025) | 1945 s (2025), extracting the 7z |
| w64devkit `2.11.0` x64 (69 MB `.7z.exe` self-extractor) | not usable | not usable | not usable | n/a | n/a |

Notes on each result:

- No missing DLL (`0xC0000135`) or entry point (`0xC0000139`) errors appeared for any toolchain that started. llvm-mingw and Zig are statically linked to their own runtimes and need nothing from the host.
- **llvm-mingw** works installed under `C:\Program Files\llvm-mingw` with `CC=x86_64-w64-mingw32-clang`. The zip carries the toolchain for four architectures (x86_64, i686, aarch64, armv7), which is why it is large. Removing the three unused target folders is a follow-up task, not tested here.
- **Zig** works, but `CC` has to contain spaces (`zig cc -target x86_64-windows-gnu`). cgo accepts that, but some build systems don't. Zig is pre-1.0, so its flags and cross-compiler behaviour can change between releases.
- **WinLibs** installs from the 7z on ltsc2025 only (its tar reads LZMA). The hello build failed with `ld.exe: cannot find C:/Program: No such file or directory` and `cannot find Files/mingw64/...default-manifest.o`, because its GCC cannot link from a path with a space. After `move "C:\Program Files\mingw64" C:\mingw64` and a PATH change, it printed `cgo says 42`. The 7z on 2022 and 2019 was not tried; the zip would work with tar everywhere but is 276 MB to download and 3 times the size on disk.
- **w64devkit**: ltsc2022's tar fails with `LZMA codec is unsupported`. Running the self-extractor in a nanoserver ltsc2022 container exited 255 with no output. Using it would need a servercore stage with 7-Zip.
- cgo hello builds are much slower than a pure Go build because the first `import "C"` build compiles Go's runtime/cgo with the C compiler.

## Smoke test results

Run against the llvm-mingw prototype (the since-removed `experiments/go-cgo/Dockerfile.llvm-mingw`):

| Script | 2025 | 2022 | 2019 |
| --- | --- | --- | --- |
| `smoke-test-cgo.ps1` | pass (`cgo says 42`) | pass | pass |
| `smoke-test-cgo-sqlcmd.ps1` (go-sqlcmd v1.10.0, needs Go 1.25.7, built with Go 1.27.3) | pass (`sqlcmd --version` prints the banner) | not run | not run |

The first sqlcmd attempt failed with `error obtaining VCS status: exit status 128` because git refuses the cloned folder's ownership in the container, so the script builds with `-buildvcs=false`.

## Decisions

1. **Toolchain: llvm-mingw, ucrt, x86_64 zip, version pinned as `LLVM_MINGW_VERSION` in the Dockerfile `ENV`.** It is the only candidate that is a plain zip (tar extracts it on 2019, 2022 and 2025 with no servercore stage), runs from `C:\Program Files`, passed on all three Windows versions, ships clang and libc++ for C++ cgo and the whole ucrt toolchain, and is actively maintained by one of the mingw-w64 authors. Tradeoffs against the others:
   - Zig is half the size, but it is pre-1.0, `CC` needs spaces, and `zig cc` first-use runtime builds make cgo builds 2 to 5 times slower here. It stays a documented alternative.
   - WinLibs GCC is the most conventional GCC, but it needs a space-free install path, a 7z that only ltsc2025's tar can read (otherwise a 276 MB zip or a servercore extraction stage), and it is the largest.
   - w64devkit is a 7z self-extractor that does not run on nanoserver, so it would always need a servercore stage.
   - ucrt rather than msvcrt: ucrt is in every supported Windows (it is a Windows component since Windows 10), supports UTF-8 and modern C, and matches what current Go and Microsoft tools use. msvcrt is the legacy runtime. Binaries built here run on all three nanoserver versions, which ship ucrt.
2. **Keep `windows-nano-go` cgo-off and add a cgo variant.** Most users want the small image, and cgo adds about 750 MB. The Dockerfile gets `ARG CGO=0`. With `CGO=1` it installs the toolchain and sets `CGO_ENABLED=1`, `CC` and `CXX`. The toolchain is a separate `RUN` layer, after Go, so Go-only changes don't invalidate it and the cgo-off image shares every layer.
3. **Tags.** The ADR 0005 tag grammar is `:<ver>[-<suffix>]`. The Go image already builds per Go version (`windows-nano-go:<go>-<win>` locally). The cgo variant adds a `cgo` segment: local `windows-nano-go:<go>-cgo-<win>`, for example `1.27.3-cgo-2025`, and published `zippy1981/windows-nano-go:<go>-cgo-<win>`. The ADR 0005 suffixes then follow the Windows version as they do today (`...-cgo-2025-10.0.26100.<rev>`, `...-cgo-2025-2026-11`, `...-cgo-2025-10.0.26100.<rev>-<sha7>`). `build.cmd` accepts `CGO=1` and picks the tag. This is recorded in a new ADR, which amends ADR 0005 for images that have variants.
4. **CI matrix: cgo only on the newest Go.** Today's matrix is Go version x Windows version, nine images. cgo on all three Go lines adds nine more images of roughly 1.6 GB each and about 15 minutes of toolchain extraction per leg. The cgo variant is built for the newest Go only, on all three Windows versions (three extra images). Older Go lines can be added by adding to the matrix. The go-container workflow gets a second job that calls `build-windows-image.yml` with `build-args: {"GO_VERSION": ..., "CGO": "1"}` and `variant: go<ver>-cgo`.
5. **Labels.** The shared workflow adds OCI labels in the publish step. Per-image custom labels go there too, never in the Dockerfile `LABEL` or the build, because a label that changes per run breaks the layer cache. The Go image would only ever have stable labels, but the convention stays simple: all labels come from the publish step. Proposed custom labels, set from the image's own `ENV` (the publish step reads them with `docker image inspect`) so the Dockerfile stays the single source of truth:
   - `com.zippy1981.go.version` from `GO_VERSION`
   - `com.zippy1981.cgo.enabled` (`true` or `false`) from `CGO_ENABLED`
   - `com.zippy1981.cgo.toolchain` (`llvm-mingw`) and `com.zippy1981.cgo.toolchain.version` (`20261104`), only when cgo is on, from `CC_TOOLCHAIN` and `CC_TOOLCHAIN_VERSION`

   The workflow change is generic: an image folder may provide `labels.ps1` or the workflow may read every `LABEL_*` environment variable on the image and publish it as a label. Pick one in phase 2.
6. **Smoke tests.** `smoke-test.ps1` stays the one entry point the shared workflow calls (ADR 0009). It checks `go env CGO_ENABLED`. When it is `1`, it also runs `smoke-test-cgo.ps1 -Image <tag>` (small, about 2 minutes) and then `smoke-test-cgo-sqlcmd.ps1 -Image <tag>` (large). The cgo-off algernon test keeps running for cgo-off images and is skipped for cgo images, since it is the same Go code. No workflow input is needed. Both scripts are in this PR.
7. **Licences.** llvm-mingw is a build of LLVM (Apache-2.0 with LLVM exceptions) and mingw-w64 (ZPL and public domain headers/runtime, with a few BSD-style files). The mingw-w64 runtime that is linked into your binaries is under permissive terms that do not require attribution in the output. Zig is MIT. WinLibs bundles GCC (GPLv3 with the GCC Runtime Library Exception), binutils (GPLv3) and GDB (GPLv3); the runtime exception keeps built programs free of GPL terms, but the image itself carries GPL components. The image README gets a "Licences" paragraph.

## Plan

### Phase 0: Prerequisites

- [x] **container-author**: Run the toolchain experiments with prototype Dockerfiles (removed after the variant landed). Accept: the results table above is filled in, and `cc --version` and a cgo hello world are recorded for llvm-mingw on 2019, 2022 and 2025.
- [x] **windows-container-tester**: Write `nano-server-go/smoke-test-cgo.ps1` and `smoke-test-cgo-sqlcmd.ps1`. Accept: both pass against the llvm-mingw prototype on ltsc2025 (results in the PR description).
- [x] **adr**: Write ADR 0013 "The Go image has a cgo variant using llvm-mingw, tagged `-cgo-`" (amending 0005 for variant tags) and add it to `docs/adr/README.md`. Accept: markdownlint passes, and the index lists it.

### Phase 1: Dockerfile

- [x] **container-author**: Add `ARG CGO=0`, `ARG CC_TOOLCHAIN=llvm-mingw` and the pinned `CC_TOOLCHAIN_VERSION` to `nano-server-go/Dockerfile`. When `CGO=1`, install the toolchain in its own layer after Go, set `CGO_ENABLED=1`, `CC`, `CXX` and add its `bin` to `PATH`. Otherwise keep `CGO_ENABLED=0`. Accept: `docker build` with `CGO=0` is byte-for-byte the same layers as today, and with `CGO=1` `go env CGO_ENABLED CC` shows `1` and the clang wrapper, for 2019, 2022 and 2025.
- [x] **container-author**: Delete the unused `aarch64`, `armv7` and `i686` target folders and their wrappers in the same `RUN` as the extraction. Accept: the cgo image is at least 300 MB smaller than the +755 MB measured, and both cgo smoke tests still pass.
- [ ] **windows-dockerfile-reviewer**: Review the Dockerfile change. Accept: no high-severity findings open.
- [x] **container-author**: Update `build.cmd` for `CGO=1` and its tag, and the README (cgo section, toolchain, licences, tags). Accept: `build.cmd` with `CGO=1` tags `windows-nano-go:<go>-cgo-<win>`, and markdownlint passes.

### Phase 2: CI

- [x] **workflow-author**: Change `smoke-test.ps1` to call the two cgo scripts when `CGO_ENABLED=1`, and skip the algernon test then. Accept: `smoke-test.ps1 -Image` passes for a cgo-off and a cgo image.
- [x] **workflow-author**: Add a cgo job to `.github/workflows/go-container.yml` for the newest Go with `CGO: "1"` and `variant: go<ver>-cgo`, and a timeout of 150 minutes (as built). Accept: actionlint is clean, and three legs (2019, 2022, 2025) go green on a branch push.
- [ ] **cicd-engineer**: Decide how custom labels reach the publish step (a per-image `labels.ps1`, or `LABEL_*` environment variables) and add `com.zippy1981.go.version`, `.cgo.enabled`, `.cgo.toolchain` and `.cgo.toolchain.version`. Accept: labels are added only in the publish step, a CI build's image ID is unchanged by them, and `docker image inspect` on a published image shows them.
- [x] **python-author**: Extend the convention tests so an image folder that has several smoke-test scripts still has `smoke-test.ps1`, and the Dockerfile's `ARG CGO` default is `0`. Accept: pytest passes, and ruff is clean at line length 120.

### Phase 3: Publish

- [ ] **cicd-engineer**: Teach the refresh matrix and ADR 0005 tagging about the `-cgo-` variant. Accept: a forced refresh on `main` publishes the four ADR 0005 tags for each cgo leg.
- [ ] **windows-container-tester**: Pull the published cgo images and run both cgo smoke tests. Accept: they pass on ltsc2019, ltsc2022 and ltsc2025 hosts or hosts that can run them.

## Risks

- **Image size.** The measured cgo image is 1.4 to 1.6 GB. The unused-target trim should recover roughly half the toolchain. Zig would be the fallback if size matters more than build time.
- **Build time.** Extracting the 191 MB zip took 10 to 15 minutes under Hyper-V with 4 GB of memory. That adds to CI time on a self-hosted runner. Mitigated by the separate layer, so it only rebuilds when the toolchain pin changes.
- **Version drift.** llvm-mingw releases often. `windows-deps-updater` must learn the pin (ADR 0007: separate from base-image refreshes).
- **Host cleanup race.** During the experiments, CI cleanup removed the `windows-nano-go:ci-*` images a toolchain build was about to use as `FROM`. Local experiment scripts should build their own base image, as `run-experiment.ps1` expects.
- **Untested.** WinLibs on 2022 and 2019, trimming the target folders, and a C++ cgo program were not run. `sqlcmd` does not need a C compiler itself, so it proves that the cgo build path works with a large module graph, not that a C library links.
- **Licences.** The mingw-w64 headers and runtime are permissive, but WinLibs would add GPL components to the image.

## Owners

- `container-author`: Dockerfile, build.cmd, README.
- `windows-dockerfile-reviewer`: review.
- `workflow-author`, `cicd-engineer`: workflow job, labels, refresh matrix.
- `python-author`: convention tests.
- `windows-container-tester`: smoke tests and published image checks.
- `adr`: ADR 0013.

## Implementation notes

Phases 1 and 2 are implemented on this branch, and the Phase 3 publishing tasks are not.

- **One Dockerfile.** `ARG CGO=0`, `ARG CC_TOOLCHAIN=llvm-mingw` and `ARG LLVM_MINGW_VERSION=20261104` sit after the Go, MinGit and micro layers. With `CGO=0` only metadata differs from before (`CGO_ENABLED` moved to the end of the file); no filesystem layer changed. With `CGO=1` one `RUN` downloads and extracts llvm-mingw into `C:\Program Files\llvm-mingw`, trims it, runs `setx PATH` (user PATH only, with the toolchain `bin` in front of the existing entries) and `go env -w CC=x86_64-w64-mingw32-clang CXX=x86_64-w64-mingw32-clang++`. `CC` is therefore not a container environment variable. `smoke-test-cgo.ps1` reads it with `go env CC`. Any `CC_TOOLCHAIN` but `llvm-mingw` with `CGO=1` fails the build with a message.
- **Trim.** The same `RUN` deletes the aarch64, armv7, i686 and arm64ec toolchains and wrappers, the per-architecture compiler-rt libraries, `python`, `busybox`, lldb, clangd and clang-tidy. Measured on ltsc2025: the plain image is 854 MB and the cgo image is 1.27 GB, so cgo adds 416 MB instead of 755 MB (339 MB smaller than the untrimmed build; the toolchain layer is 419 MB). The plan's target was at least 300 MB.
- **Smoke tests, ltsc2025 on this host.** `smoke-test.ps1` on the plain image passes (hello, a cgo build fails as expected, algernon). On the cgo image it passes (hello, `cgo says 42`, sqlcmd v1.10.0 built with cgo). ltsc2022 and ltsc2019 were not run locally; CI covers them. Moving `CC` from `ENV` to `go env -w` broke the prototype's `%CC%` check in `smoke-test-cgo.ps1`, which is fixed.
- **Convention tests.** `tests/test_images.py` gets `TestGoCgo`: `ARG CGO=0` exists and comes after the Go install `RUN`. `build-windows-image.yml` still rejects `WINDOWS_VERSION` and `BASE_IMAGE` in `build-args`.
- **CI.** `go-container.yml` uses explicit `include` entries: the three plain Go lines with `cgo: '0'` and one `1.27.3` entry with `cgo: '1'`, `variant: go1.27.3-cgo` and a 150 minute timeout (90 for the others). The job `name` is set to `build (<go>[-cgo])` so `scripts/ci_speed.py` still parses it. The entries also carry `tag-prefix` and `also-plain-tags` to match the shape on the variant-publishing branch; they are not passed to the shared workflow yet because it has no such inputs on this branch.
- **Published since variant publishing (#42) landed.** The cgo leg publishes under its own `1.27.3-cgo-<win>` tags, and `scripts/refresh_matrix.py` expands the matrix, so refreshes rebuild it too. Earlier note, kept for history: the shared workflow's publish step used to tag only by Windows version, so publishing the cgo leg would have overwritten the plain image's tags. `image-refresh.yml` and `scripts/refresh_matrix.py` never pass `CGO` or any build argument, so refreshes build and publish only the plain image. The cgo leg is build and test only until the shared workflow gains variant-aware tags (`<go>-cgo-<win>` plus the ADR 0005 suffixes). This is recorded in [ADR 0012](../docs/adr/0013-the-go-image-has-a-cgo-variant-using-llvm-mingw.md) (Proposed), which defers the tag scheme to the amended ADR 0005.
- **Left for later.** The custom labels (CI task), the `-cgo-` publish and refresh teaching (Phase 3), the `windows-dockerfile-reviewer` pass, `windows-deps-updater` learning the llvm-mingw pin, and the published-image checks.
