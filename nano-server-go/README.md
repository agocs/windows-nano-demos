# Go development windows nano server container

A Windows nanoserver container for Go development. It contains:

- [Go](https://go.dev/) for windows-amd64: 1.27.3 by default, or any version through `GO_VERSION`. `CGO_ENABLED=0` because there is no C compiler on nanoserver, and `GOTOOLCHAIN=local`, so `go` never downloads a different toolchain behind your back.
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

CI builds the latest patch of the three newest Go releases, currently 1.27.3, 1.26.10 and 1.25.14, on each of the three Windows versions: nine images. Every one compiles and runs a hello world module with its own Go. The algernon build in `smoke-test.ps1` needs the Go version from algernon's `go.mod` (1.27.3 for v1.17.12), so images with an older Go skip it and print why.

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
