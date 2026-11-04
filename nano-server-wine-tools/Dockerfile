ARG WINDOWS_VERSION=2022
# Use the official Microsoft Windows Nano Server image unless another base is passed in
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64

# ---------- check: every import of every Wine tool must resolve against this exact base ----------
# wine-pe\ holds the unmodified x86_64 PE programs from WineHQ's wine-stable 11.0 .deb, put there by
# fetch-wine.ps1 (local builds) or by the CI artifact from extract-wine.sh. They are not in git.
FROM ${BASE_IMAGE} AS check
ENV POWERSHELL_VERSION=7.6.9
RUN mkdir C:\Users\ContainerUser\pwsh && \
    curl -fsSL --retry 5 --retry-delay 5 -o C:\Users\ContainerUser\pwsh.zip https://github.com/PowerShell/PowerShell/releases/download/v%POWERSHELL_VERSION%/PowerShell-%POWERSHELL_VERSION%-win-x64.zip && \
    tar -xf C:\Users\ContainerUser\pwsh.zip -C C:\Users\ContainerUser\pwsh && \
    del C:\Users\ContainerUser\pwsh.zip
COPY wine-pe/ C:/wine-pe/
COPY scripts/ C:/scripts/
RUN C:\Users\ContainerUser\pwsh\pwsh.exe -NoLogo -NoProfile -File C:\scripts\Test-PeImports.ps1 -Path C:\wine-pe -System32 C:\Windows\System32

# ---------- final ----------
FROM ${BASE_IMAGE}
ARG WINE_VERSION=11.0
LABEL org.opencontainers.image.source="https://github.com/zippy1981/windows-nano-demos" \
      org.opencontainers.image.licenses="LGPL-2.1-or-later" \
      org.winehq.version="${WINE_VERSION}"

# Without this, Wine's stub code paths print fixme: lines to stderr. winecrt0's fallback honours it on Windows.
ENV WINEDEBUG=-all

# Copying from the check stage makes the final stage depend on it, so the import check always runs.
COPY --from=check ["C:/wine-pe/", "C:/Program Files/wine-tools/"]
COPY ["licenses/", "C:/Program Files/wine-tools/"]
COPY ["SOURCE.md", "C:/Program Files/wine-tools/"]
COPY tests/ C:/tests/
COPY tools.txt C:/tests/tools.txt

# C:\work is scratch space for the tests (cabinets, hard links), writable by the default user.
USER ContainerAdministrator
RUN mkdir C:\work && icacls C:\work /grant "User Manager\ContainerUser:(OI)(CI)M" && \
    icacls C:\tests /grant "User Manager\ContainerUser:(OI)(CI)M"
USER ContainerUser

# The Wine tools go after the system PATH (the user PATH is appended to it), so nothing nanoserver
# ships is shadowed. Set path. In nano 2019 we need to make the users environment key before we can
# add values to it. We dont need the call to reg.exe in 2022
RUN reg query HKCU\Environment 2> NUL || reg add HKCU\Environment /v PATH
RUN setx PATH "C:\Program Files\wine-tools"

# The container has two users, ContainerAdministrator and ContainerUser.
# They don't show up in the Net User command, but they have profile directories with registry hives.
WORKDIR C:/users/containeruser

# Set the entry point and default command
ENTRYPOINT ["cmd", "/S", "/C"]
CMD ["cmd"]
