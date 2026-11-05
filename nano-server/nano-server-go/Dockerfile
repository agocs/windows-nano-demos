ARG WINDOWS_VERSION=2025
# Use the official Microsoft Windows Nano Server image unless BASE_IMAGE overrides it
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64
FROM ${BASE_IMAGE}

# The Go toolchain version (issue #20). CI builds the three newest Go releases, and the default is the newest.
ARG GO_VERSION=1.27.3

# Pinned tool versions and install locations.
# CGO_ENABLED=0 because there is no C compiler on nanoserver.
# GOTOOLCHAIN=local: always use this image's Go, and never download a newer one that a go.mod asks for.
ENV \
    GO_VERSION=${GO_VERSION} \
    GOTOOLCHAIN=local \
    GOROOT="C:\\Program Files\\go" \
    GOPATH="C:\\users\\containeruser\\go" \
    CGO_ENABLED=0 \
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

# The container has two users, ContainerAdministrator and ContainerUser.
# They don't show up in the Net User command, but they have profile directories with registry hives.
WORKDIR C:/users/containeruser

# Set the entry point and default command
ENTRYPOINT ["cmd", "/S", "/C"]
