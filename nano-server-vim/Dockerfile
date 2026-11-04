ARG WINDOWS_VERSION=2022
# This image uses servercore instead of nanoserver: vim64.dll (which vim.exe loads) imports
# kernel32!DebugBreakProcess, gdi32!GetNearestColor/SetAbortProc and winmm!mciSendString*, which the
# nanoserver ltsc2019, ltsc2022 and ltsc2025 forwarder DLLs do not export, so vim fails to start with
# STATUS_ENTRYPOINT_NOT_FOUND (0xC0000139). kernel32.dll can't be replaced inside a container.
# Nanoserver also lacks netapi32.dll, which vim64.dll imports as well.
ARG BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc${WINDOWS_VERSION}

# vim.exe and vim64.dll use the static CRT, but the bundled libsodium.dll (used for :X encryption)
# needs vcruntime140.dll, which neither Nano Server nor Server Core ships. The official Python
# embeddable zip redistributes it, so we take it from there. Nothing is copied from the host, so this works in CI.
FROM mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64 AS vcrt
ENV PYTHON_EMBED_VERSION=3.14.0
RUN mkdir C:\vcrt && \
    curl -fL -o C:\vcrt\python.zip https://www.python.org/ftp/python/%PYTHON_EMBED_VERSION%/python-%PYTHON_EMBED_VERSION%-embed-amd64.zip && \
    tar -xf C:\vcrt\python.zip -C C:\vcrt vcruntime140.dll vcruntime140_1.dll && \
    del C:\vcrt\python.zip

FROM ${BASE_IMAGE}

# Pinned tool versions.
# VIM_DIR depends on the major/minor version (vim92 for 9.2.x); update it along with VIM_VERSION.
# MinGit is installed to "MinGit" rather than "Git" on purpose: its etc\gitconfig includes
# "C:/Program Files/Git/etc/gitconfig", so installing it there makes git include itself
# until it fails with "exceeded maximum include depth".
ENV \
    VIM_VERSION=9.2.1286 \
    VIM_DIR="C:\\Program Files\\vim\\vim92" \
    MINGIT_TAG=v2.56.0.windows.4 \
    MINGIT_VERSION=2.56.0.4 \
    MINGIT_DIR="C:\\Program Files\\MinGit"

COPY --from=vcrt C:/vcrt/ C:/Windows/System32/

# Vim. The x64 "gvim" zip contains the console vim.exe as well as gvim.exe.
# We download to a file and then extract because piping curl into tar does not always extract every file.
RUN mkdir "%VIM_DIR%" && \
    curl -fL -o vim.zip https://github.com/vim/vim-win32-installer/releases/download/v%VIM_VERSION%/gvim_%VIM_VERSION%_x64.zip && \
    tar -xf vim.zip -C "%ProgramFiles%" && \
    del vim.zip

# MinGit (non-busybox) so plugin managers can clone plugins.
RUN mkdir "%MINGIT_DIR%" && \
    curl -fL -o mingit.zip https://github.com/git-for-windows/git/releases/download/%MINGIT_TAG%/MinGit-%MINGIT_VERSION%-64-bit.zip && \
    tar -xf mingit.zip -C "%MINGIT_DIR%" && \
    del mingit.zip

# Add what we installed to the path
# The users path is empty at this point so we dont need to append
# Set path. In nano 2019 we need to make the users environment key before we can add values to it. We dont need the call to reg.exe in 2022
RUN reg query HKCU\Environment 2> NUL || reg add HKCU\Environment /v PATH
RUN setx PATH "%VIM_DIR%;%MINGIT_DIR%\cmd"

# The container has two users, ContainerAdministrator and ContainerUser.
# They don't show up in the Net User command, but they have profile directories with registry hives.
WORKDIR C:/users/containeruser

# Set the entry point and default command
ENTRYPOINT ["cmd", "/S", "/C"]
