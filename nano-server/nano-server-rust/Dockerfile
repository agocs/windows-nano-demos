# windows-nano-rust: Rust (gnu toolchain) with cargo, MinGit and the micro editor on Nano Server.
#
# Build from this folder (build.cmd does the same, and also tags zippy1981/windows-nano-rust):
#   docker build --memory 4g --build-arg WINDOWS_VERSION=2022 -t windows-nano-rust:2022 .
# Each build argument is described where it is declared below.

# Windows Server LTSC version to build for: 2019, 2022 or 2025 (the default). Set with --build-arg WINDOWS_VERSION=2022.
ARG WINDOWS_VERSION=2025
# The image the final stage is built on. Defaults to Nano Server for WINDOWS_VERSION; CI pins it to a digest.
# Set with --build-arg BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc2022-amd64.
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64
FROM ${BASE_IMAGE}

# Set environment variables. Every tool version is pinned here.
# We use the x86_64-pc-windows-gnu toolchain instead of MSVC. The MSVC toolchain needs link.exe
# and the Windows SDK, which come from the Visual Studio Build Tools installer, and that can't run
# on nanoserver. The gnu toolchain ships its own self-contained mingw linker (the rust-mingw component).
ENV \
    RUSTUP_VERSION=1.29.3 \
    RUST_VERSION=1.99.1 \
    RUST_HOST=x86_64-pc-windows-gnu \
    RUSTUP_HOME="C:\\rust\\rustup" \
    CARGO_HOME="C:\\rust\\cargo" \
    MINGIT_VERSION=2.56.0.4 \
    MINGIT_TAG=v2.56.0.windows.4 \
    MINGIT_PATH="C:\\Program Files\\MinGit" \
    MICROEDITOR_VERSION=2.0.15 \
    MICROEDITOR_PATH="C:\\Program Files\\micro-2.0.15"

# Install rustup and the gnu toolchain with the minimal profile (rustc, cargo, rust-std, rust-mingw)
# Hyper-V isolated build containers get 1 GB of RAM by default. rustup's parallel unpacker filled that and
# rustup-init stalled (idle at ~1 GB working set) on uncached CI builds, so we cap its I/O threads and unpack buffer.
RUN mkdir "%RUSTUP_HOME%" "%CARGO_HOME%" && \
    curl -fL -o rustup-init.exe https://static.rust-lang.org/rustup/archive/%RUSTUP_VERSION%/%RUST_HOST%/rustup-init.exe && \
    set "RUSTUP_IO_THREADS=1" && \
    set "RUSTUP_UNPACK_RAM=268435456" && \
    rustup-init.exe -y --no-modify-path --profile minimal --default-host %RUST_HOST% --default-toolchain %RUST_VERSION% && \
    del rustup-init.exe

# Install MinGit (the non-busybox build)
RUN mkdir "%MINGIT_PATH%" && \
    curl -fL -o mingit.zip https://github.com/git-for-windows/git/releases/download/%MINGIT_TAG%/MinGit-%MINGIT_VERSION%-64-bit.zip && \
    tar -xf mingit.zip -C "%MINGIT_PATH%" && \
    del mingit.zip

# Install micro editor
RUN mkdir "%MICROEDITOR_PATH%" && \
    curl -fLO https://github.com/micro-editor/micro/releases/download/v%MICROEDITOR_VERSION%/micro-%MICROEDITOR_VERSION%-win64.zip && \
    tar -xf micro-%MICROEDITOR_VERSION%-win64.zip -C "%ProgramFiles%" && \
    del micro-%MICROEDITOR_VERSION%-win64.zip

# Add what we installed to the path
# The users path is empty at this point so we dont need to append
# Set path. In nano 2019 we need to make the users environment key before we can add values to it. We dont need the call to reg.exe in 2022
RUN reg query HKCU\Environment 2> NUL || reg add HKCU\Environment /v PATH
RUN setx PATH "%CARGO_HOME%\bin;%MINGIT_PATH%\cmd;%MICROEDITOR_PATH%"

# The container has two users, ContainerAdministrator and ContainerUser.
# They don't show up in the Net User command, but they have profile directories with registry hives.
WORKDIR C:/users/containeruser

# Set the entry point and default command
ENTRYPOINT ["cmd", "/S", "/C"]
