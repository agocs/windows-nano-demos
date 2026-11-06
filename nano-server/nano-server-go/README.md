# Go development windows nano server container

A Windows nanoserver container for Go development. It contains:

- [Go](https://go.dev/) for windows-amd64: 1.27.3 by default, or any version through `GO_VERSION`. `CGO_ENABLED=0` by default because there is no C compiler on nanoserver (see [cgo](#cgo) to build one that has), and `GOTOOLCHAIN=local`, so `go` never downloads a different toolchain behind your back.
- [MinGit](https://github.com/git-for-windows/git/releases) 2.56.0 so `go get` and modules hosted in git repositories work
- The [micro](https://micro-editor.github.io/) text editor

`GOPATH` is `C:\users\containeruser\go`. Both the Go `bin` folder and `%GOPATH%\bin` are in your path, so tools installed with `go install` can be run directly.

Will be available at <https://hub.docker.com/r/zippy1981/windows-nano-go>.

## Building

To build a 2025 container, the default:

```cmd
build.cmd
```

To build the windows 2019 container:

From powershell

```pwsh
$env:WINDOWS_VERSION=2019
./build.cmd
```

The Command Prompt

```cmd
set WINDOWS_VERSION=2019
build.cmd
```

`WINDOWS_VERSION` can be `2019`, `2022` or `2025`. To use a different base image, set `BASE_IMAGE` (for example `mcr.microsoft.com/windows/nanoserver:ltsc2025-amd64`) and `build.cmd` passes it to `docker build`.

### Go version

`GO_VERSION` picks the Go toolchain, for example `set GO_VERSION=1.25.14` before `build.cmd`. `build.cmd` then also tags the image `windows-nano-go:<go version>-<windows version>`.

CI builds the latest patch of the three newest Go releases, currently 1.27.3, 1.26.10 and 1.25.14, on each of the three Windows versions: nine images. Each is published on Docker Hub with its Go version as a tag prefix (ADR 0005):

| Tag | What it is |
| --- | --- |
| `zippy1981/windows-nano-go:2025` | The newest Go (1.27.3) on ltsc2025. It moves when Go or the base image changes. |
| `zippy1981/windows-nano-go:1.26.10-2025` | Go 1.26.10 on ltsc2025. |
| `zippy1981/windows-nano-go:1.26.10-2025-<os-build>` and `:1.26.10-2025-YYYY-MM` | The same, pinned to a base image build or a month. |
| `zippy1981/windows-nano-go:1.26.10-2025-<os-build>-<sha7>` | Immutable. |

The same pattern applies to `2019` and `2022`. Every one compiles and runs a hello world module with its own Go. The algernon build in `smoke-test.ps1` needs the Go version from algernon's `go.mod` (1.27.3 for v1.17.12), so images with an older Go skip it and print why.

### cgo

`CGO=1` builds a variant with a C toolchain, so `import "C"` and modules that use cgo build inside the container:

```cmd
set CGO=1
build.cmd
```

It tags the image `windows-nano-go:<go version>-cgo-<windows version>` (or `windows-nano-go:cgo-<windows version>` when `GO_VERSION` is unset) and never the plain tags. `go env CGO_ENABLED CC CXX` then shows `1`, `x86_64-w64-mingw32-clang` and `x86_64-w64-mingw32-clang++`. `CC_TOOLCHAIN` names the toolchain; `llvm-mingw` is the default and the only one supported, and any other value fails the build.

- Toolchain: [llvm-mingw](https://github.com/mstorsjo/llvm-mingw) 20261104 (clang 23, mingw-w64, ucrt, x86_64), pinned as `LLVM_MINGW_VERSION` in the Dockerfile. It is a plain zip that nanoserver's `tar` extracts on all three Windows versions.
- Size: about 1.27 GB on ltsc2025, 416 MB more than the plain 854 MB image (the untrimmed toolchain added 755 MB). Extracting the zip takes 10 to 15 minutes under Hyper-V, but the toolchain is its own layer after Go, MinGit and micro, so it rebuilds only when the pin changes, and the plain image shares every other layer.
- The Dockerfile deletes the unusable i686, aarch64, armv7 and arm64ec toolchains, and lldb, clangd, clang-tidy and Python, in the same step as the extraction.
- The first `import "C"` build is slow because Go compiles its `runtime/cgo` with clang.
- Licences: llvm-mingw is LLVM (Apache-2.0 with LLVM exceptions) and mingw-w64 (permissive ZPL, public domain and BSD-style licences). Programs you build with it carry no GPL terms.
- CI builds and tests this variant for the newest Go on all three Windows versions. `smoke-test.ps1` sees `CGO_ENABLED=1` and also runs `smoke-test-cgo.ps1` (a C function called from Go) and `smoke-test-cgo-sqlcmd.ps1` (builds [go-sqlcmd](https://github.com/microsoft/go-sqlcmd) with cgo). On the plain image it checks that a cgo build fails. It is published as `zippy1981/windows-nano-go:1.27.3-cgo-<windows version>` (with the other ADR 0005 tags under the same prefix), and the image refresh rebuilds it with the plain images. See [ADR 0013](../../docs/adr/0013-the-go-image-has-a-cgo-variant-using-llvm-mingw.md).

### Memory

`build.cmd` passes `--memory 4g` because Hyper-V isolated builds default to 1 GB, and extracting the Go zip can hang with that little memory.

## Usage

Run a shell:

```cmd
docker run -it --rm windows-nano-go:2025 cmd
```

Quick check of the tools:

```cmd
docker run --rm windows-nano-go:2025 "go version && git --version && micro -version"
```
