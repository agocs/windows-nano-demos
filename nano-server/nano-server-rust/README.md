# Rust development windows nano server container

Rust, cargo, git (MinGit) and the micro text editor on Windows nano server.

`cargo new hello && cd hello && cargo run` works inside the container.

## Why the gnu toolchain

The default Rust toolchain on Windows is `x86_64-pc-windows-msvc`. It needs `link.exe` and the Windows SDK, which only come from the Visual Studio Build Tools installer. That installer can't run on nano server (no MSI, no PowerShell), so this image uses the `x86_64-pc-windows-gnu` toolchain instead. It ships a self-contained mingw linker, so nothing else has to be installed.

Crates that link against MSVC-only libraries won't build here.

## Layout

- `RUSTUP_HOME` is `C:\rust\rustup`
- `CARGO_HOME` is `C:\rust\cargo`, and `C:\rust\cargo\bin` is on the path
- MinGit is in `C:\Program Files\MinGit`
- micro is in `C:\Program Files\micro-<version>`

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

The same works for `2025`. CI builds and tests 2019, 2022 and 2025.

The base image defaults to `mcr.microsoft.com/windows/nanoserver:ltsc<WINDOWS_VERSION>-amd64`. To use a different one, set `BASE_IMAGE` before running `build.cmd`. It is passed to `docker build` as `--build-arg BASE_IMAGE`.

```cmd
set BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc2022-amd64
build.cmd
```

## Running

```cmd
docker run -it --rm windows-nano-rust:2022 cmd
```
