ARG WINDOWS_VERSION=2022
# This image uses servercore instead of nanoserver: nvim.exe imports kernel32!DebugBreakProcess,
# which the kernel32.dll in nanoserver ltsc2019, ltsc2022 and ltsc2025 does not export, so it fails
# to start with STATUS_ENTRYPOINT_NOT_FOUND (0xC0000139). kernel32.dll can't be replaced inside a
# container. Nanoserver also lacks netapi32.dll, which nvim.exe imports as well.
ARG BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc${WINDOWS_VERSION}

# Neither Nano Server nor Server Core ships the Visual C++ runtime (vcruntime140.dll), and we don't
# want to run the vc_redist installer. The official Python embeddable zip redistributes
# vcruntime140.dll, so we take it from there. Nothing is copied from the host, so this works in CI.
FROM mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64 AS vcrt
ENV PYTHON_EMBED_VERSION=3.14.0
RUN mkdir C:\vcrt && \
    curl -fL -o C:\vcrt\python.zip https://www.python.org/ftp/python/%PYTHON_EMBED_VERSION%/python-%PYTHON_EMBED_VERSION%-embed-amd64.zip && \
    tar -xf C:\vcrt\python.zip -C C:\vcrt vcruntime140.dll vcruntime140_1.dll && \
    del C:\vcrt\python.zip

FROM ${BASE_IMAGE}

# Pinned tool versions.
# MinGit is installed to "MinGit" rather than "Git" on purpose: its etc\gitconfig includes
# "C:/Program Files/Git/etc/gitconfig", so installing it there makes git include itself
# until it fails with "exceeded maximum include depth".
ENV \
    NEOVIM_VERSION=0.12.6 \
    NEOVIM_DIR="C:\\Program Files\\nvim-win64" \
    MINGIT_TAG=v2.56.0.windows.4 \
    MINGIT_VERSION=2.56.0.4 \
    MINGIT_DIR="C:\\Program Files\\MinGit"

COPY --from=vcrt C:/vcrt/ C:/Windows/System32/

# Neovim.
# We download to a file and then extract because piping curl into tar does not always extract every file.
RUN mkdir "%NEOVIM_DIR%" && \
    curl -fL -o nvim.zip https://github.com/neovim/neovim/releases/download/v%NEOVIM_VERSION%/nvim-win64.zip && \
    tar -xf nvim.zip -C "%ProgramFiles%" && \
    del nvim.zip

# MinGit (non-busybox) so plugin managers can clone plugins.
RUN mkdir "%MINGIT_DIR%" && \
    curl -fL -o mingit.zip https://github.com/git-for-windows/git/releases/download/%MINGIT_TAG%/MinGit-%MINGIT_VERSION%-64-bit.zip && \
    tar -xf mingit.zip -C "%MINGIT_DIR%" && \
    del mingit.zip

# Add what we installed to the path
# The users path is empty at this point so we dont need to append
# Set path. In nano 2019 we need to make the users environment key before we can add values to it. We dont need the call to reg.exe in 2022
RUN reg query HKCU\Environment 2> NUL || reg add HKCU\Environment /v PATH
RUN setx PATH "%NEOVIM_DIR%\bin;%MINGIT_DIR%\cmd"

# The container has two users, ContainerAdministrator and ContainerUser.
# They don't show up in the Net User command, but they have profile directories with registry hives.
WORKDIR C:/users/containeruser

# Set the entry point and default command
ENTRYPOINT ["cmd", "/S", "/C"]
