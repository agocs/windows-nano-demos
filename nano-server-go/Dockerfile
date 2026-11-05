ARG WINDOWS_VERSION=2025
# Use the official Microsoft Windows Nano Server image unless BASE_IMAGE overrides it
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64
FROM ${BASE_IMAGE}

# The Go toolchain version (issue #20). CI builds the three newest Go releases, and the default is the newest.
ARG GO_VERSION=1.27.3

# Pinned tool versions and install locations.
# CGO_ENABLED is set below, after the optional C toolchain. nanoserver has no C compiler, so the default is off.
# GOTOOLCHAIN=local: always use this image's Go, and never download a newer one that a go.mod asks for.
ENV \
    GO_VERSION=${GO_VERSION} \
    GOTOOLCHAIN=local \
    GOROOT="C:\\Program Files\\go" \
    GOPATH="C:\\users\\containeruser\\go" \
    MINGIT_VERSION=2.56.0 \
    MINGIT_RELEASE=2.56.0.windows.4 \
    MINGIT_BUILD=2.56.0.4 \
    MINGIT_DIR="C:\\Program Files\\MinGit" \
    MICROEDITOR_VERSION=2.0.15 \
    MICROEDITOR_PATH="C:\\Program Files\\micro-2.0.15"

# Go, MinGit and micro need no host DLLs, so unlike the PHP image there is no
# COPY system32\* step. If one is ever needed, stage it in build.cmd and add the COPY here.

# Download and install Go. Nanoserver has no "C:\Program Files" folder until we mkdir under it.
# Download to a file first; piping a zip into tar does not always extract every file.
RUN mkdir "%GOROOT%" && \
    curl -fLO https://go.dev/dl/go%GO_VERSION%.windows-amd64.zip && \
    tar -xf go%GO_VERSION%.windows-amd64.zip -C "%ProgramFiles%" && \
    del go%GO_VERSION%.windows-amd64.zip

# Install MinGit (non-busybox) so go get / modules can fetch from git repositories
RUN mkdir "%MINGIT_DIR%" && \
    curl -fLO https://github.com/git-for-windows/git/releases/download/v%MINGIT_RELEASE%/MinGit-%MINGIT_BUILD%-64-bit.zip && \
    tar -xf MinGit-%MINGIT_BUILD%-64-bit.zip -C "%MINGIT_DIR%" && \
    del MinGit-%MINGIT_BUILD%-64-bit.zip

# Install micro editor
RUN mkdir "%MICROEDITOR_PATH%" && \
    curl -fLO https://github.com/micro-editor/micro/releases/download/v%MICROEDITOR_VERSION%/micro-%MICROEDITOR_VERSION%-win64.zip && \
    tar -xf micro-%MICROEDITOR_VERSION%-win64.zip -C "%ProgramFiles%" && \
    del micro-%MICROEDITOR_VERSION%-win64.zip

# Add what we installed to the path
# The users path is empty at this point so we dont need to append
# Set path. In nano 2019 we need to make the users environment key before we can add values to it. We dont need the call to reg.exe in 2022
RUN reg query HKCU\Environment 2> NUL || reg add HKCU\Environment /v PATH
RUN mkdir "%GOPATH%\bin" && \
    setx PATH "%GOROOT%\bin;%GOPATH%\bin;%MINGIT_DIR%\cmd;%MICROEDITOR_PATH%"

# Optional cgo support (plans/go-cgo.md). These come after the Go, MinGit and micro layers so the cgo-off and cgo-on builds
# share them. CGO=0 (the default) changes nothing in the filesystem. CGO=1 installs llvm-mingw (clang, ucrt, x86_64), which is
# a plain zip that nanoserver's tar can extract on ltsc2019, ltsc2022 and ltsc2025.
ARG CGO=0
ARG CC_TOOLCHAIN=llvm-mingw
ARG LLVM_MINGW_VERSION=20261104

RUN if "%CGO%"=="1" if not "%CC_TOOLCHAIN%"=="llvm-mingw" (echo CC_TOOLCHAIN=%CC_TOOLCHAIN% is not supported, only llvm-mingw is && exit /b 1)

# The zip carries toolchains for x86_64, i686, aarch64 and armv7 (plus arm64ec wrappers); only x86_64 is usable here, so the rest
# is deleted in the same RUN to keep the layer small. Debugger and IDE tools (lldb, clangd, clang-tidy, python) are not needed to build.
RUN if "%CGO%"=="1" ( \
    curl -fLO https://github.com/mstorsjo/llvm-mingw/releases/download/%LLVM_MINGW_VERSION%/llvm-mingw-%LLVM_MINGW_VERSION%-ucrt-x86_64.zip && \
    tar -xf llvm-mingw-%LLVM_MINGW_VERSION%-ucrt-x86_64.zip -C "%ProgramFiles%" && \
    del llvm-mingw-%LLVM_MINGW_VERSION%-ucrt-x86_64.zip && \
    ren "%ProgramFiles%\llvm-mingw-%LLVM_MINGW_VERSION%-ucrt-x86_64" llvm-mingw && \
    cd /d "%ProgramFiles%\llvm-mingw" && \
    (for %a in (aarch64 armv7 i686 arm64ec) do (if exist %a-w64-mingw32 rmdir /s /q %a-w64-mingw32) & del /q /f bin\%a-w64-* 2>NUL & ver >NUL) && \
    (for /d %v in (lib\clang\*) do del /q /f %v\lib\windows\*-aarch64.* %v\lib\windows\*-arm.* %v\lib\windows\*-i386.* 2>NUL & ver >NUL) && \
    rmdir /s /q python busybox && \
    (del /q /f bin\lldb* bin\liblldb.dll bin\libpython* bin\clangd.exe bin\clang-tidy.exe 2>NUL & ver >NUL) && \
    setx PATH "%ProgramFiles%\llvm-mingw\bin;%GOROOT%\bin;%GOPATH%\bin;%MINGIT_DIR%\cmd;%MICROEDITOR_PATH%" && \
    go env -w CC=x86_64-w64-mingw32-clang CXX=x86_64-w64-mingw32-clang++ \
    )

ENV CGO_ENABLED=${CGO}

# The container has two users, ContainerAdministrator and ContainerUser.
# They don't show up in the Net User command, but they have profile directories with registry hives.
WORKDIR C:/users/containeruser

# Set the entry point and default command
ENTRYPOINT ["cmd", "/S", "/C"]
