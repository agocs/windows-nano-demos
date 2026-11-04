ARG WINDOWS_VERSION=2025
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64
# GitHub Actions self-hosted runner on Windows nano server.
# It has the docker CLI but no daemon. Run it with the host's docker pipe mounted, which needs process isolation:
#   docker run --isolation=process -v \\.\pipe\docker_engine:\\.\pipe\docker_engine ...
# See run-runner.ps1.
FROM ${BASE_IMAGE}

ENV \
    RUNNER_VERSION=2.338.2 \
    DOCKER_VERSION=29.9.3 \
    PWSH_VERSION=7.6.9 \
    MINGIT_VERSION=2.56.0.4 \
    MINGIT_TAG=v2.56.0.windows.4 \
    RUNNER_DIR="C:\\actions-runner" \
    PWSH_DIR="C:\\Program Files\\PowerShell\\7" \
    DOCKER_DIR="C:\\Program Files\\docker" \
    MINGIT_DIR="C:\\Program Files\\MinGit"

# The runner configures itself and writes to its own folder, and docker pipe access is easier as admin
USER ContainerAdministrator

# PowerShell: nano server doesn't ship it, and many actions (and the runner's default Windows shell) need pwsh
RUN mkdir "%PWSH_DIR%" && \
    curl -fLo pwsh.zip https://github.com/PowerShell/PowerShell/releases/download/v%PWSH_VERSION%/PowerShell-%PWSH_VERSION%-win-x64.zip && \
    tar -xf pwsh.zip -C "%PWSH_DIR%" && \
    del pwsh.zip && \
    copy "%PWSH_DIR%\pwsh.exe" "%PWSH_DIR%\powershell.exe"
# The copy above: the runner shells out to powershell.exe, which nano server doesn't have, so pwsh stands in for it

# Docker CLI only. The zip also contains dockerd.exe, which we don't need.
RUN curl -fLo docker.zip https://download.docker.com/win/static/stable/x86_64/docker-%DOCKER_VERSION%.zip && \
    tar -xf docker.zip -C "%ProgramFiles%" docker/docker.exe && \
    del docker.zip

# Not GIT_DIR: git reads that as the repository location.
# MinGit goes in its own folder: its etc/gitconfig includes "C:/Program Files/Git/etc/gitconfig", so installing it there makes a circular include
# MinGit so actions/checkout does a real clone instead of falling back to the REST API tarball.
# The busybox flavour, because git submodule (which checkout always calls) is a shell script and plain MinGit has no sh.
RUN mkdir "%MINGIT_DIR%" && \
    curl -fLo mingit.zip https://github.com/git-for-windows/git/releases/download/%MINGIT_TAG%/MinGit-%MINGIT_VERSION%-busybox-64-bit.zip && \
    tar -xf mingit.zip -C "%MINGIT_DIR%" && \
    del mingit.zip

# The runner itself. It is self-contained .NET, so nano server can run it.
RUN mkdir "%RUNNER_DIR%" && \
    curl -fLo runner.zip https://github.com/actions/runner/releases/download/v%RUNNER_VERSION%/actions-runner-win-x64-%RUNNER_VERSION%.zip && \
    tar -xf runner.zip -C "%RUNNER_DIR%" && \
    del runner.zip

# We are ContainerAdministrator, so set the machine path
RUN setx /M PATH "%PATH%;%PWSH_DIR%;%DOCKER_DIR%;%MINGIT_DIR%\cmd"

COPY start.ps1 C:/actions-runner/start.ps1

WORKDIR C:/actions-runner

ENTRYPOINT ["C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoLogo", "-NoProfile", "-File", "C:\\actions-runner\\start.ps1"]
