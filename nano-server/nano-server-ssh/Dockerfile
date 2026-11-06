# windows-nano-ssh: Win32-OpenSSH server where clients log in as real local Windows users (password or key).
#
# For ltsc2025, build with BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2025-amd64
# (build.cmd and CI do). Nanoserver 2025 rejects every local-account logon:
# LsaLogonUser S4U returns 0xC00000DF STATUS_NO_SUCH_DOMAIN, LogonUser error 1355.
#
# Build from this folder (build.cmd does the same, and also tags zippy1981/windows-nano-ssh):
#   docker build --memory 4g --build-arg WINDOWS_VERSION=2022 -t windows-nano-ssh:2022 .
# Each build argument is described where it is declared below.

# Windows Server LTSC version to build for: 2019, 2022 or 2025 (the default). Set with --build-arg WINDOWS_VERSION=2022.
ARG WINDOWS_VERSION=2025
# The image the final stage is built on. Defaults to Nano Server for WINDOWS_VERSION; CI pins it to a digest.
# Set with --build-arg BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc2022-amd64.
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64

# Helper stage. Nanoserver has no netapi32.dll, which sshd.exe, sshd-session.exe
# and ssh.exe all import; without it they die with 0xC0000135
# (STATUS_DLL_NOT_FOUND). Nanoserver also lacks whoami.exe. Both are copied from
# the servercore image of the same Windows build so their versions match.
FROM mcr.microsoft.com/windows/servercore:ltsc${WINDOWS_VERSION}-amd64 AS servercore

FROM ${BASE_IMAGE}

ENV \
    OPENSSH_VERSION=10.4.0.0p1-Preview \
    OPENSSH_DIR="C:\\Program Files\\OpenSSH-Win64"

# Creating local users and writing to C:\ProgramData\ssh needs an administrator.
USER ContainerAdministrator

COPY --from=servercore C:/windows/system32/netapi32.dll C:/windows/system32/whoami.exe C:/windows/system32/

# Win32-OpenSSH from the PowerShell GitHub releases. The zip holds a single OpenSSH-Win64 folder.
RUN mkdir "%OPENSSH_DIR%" && \
    curl -fL -o OpenSSH-Win64.zip https://github.com/PowerShell/Win32-OpenSSH/releases/download/%OPENSSH_VERSION%/OpenSSH-Win64.zip && \
    tar -xf OpenSSH-Win64.zip -C "%ProgramFiles%" && \
    del OpenSSH-Win64.zip && \
    if not exist "%ProgramData%\ssh" mkdir "%ProgramData%\ssh"

# sshd must run as LocalSystem: it builds the logged-on user's token with S4U, and
# when started directly as ContainerAdministrator every public-key logon fails with
#   get_user_token - unable to generate user token for alice as i am not running as system
# so register it as a service (same settings install-sshd.ps1 uses) and start it at run time.
# A servercore BASE_IMAGE (2025) already has an inbox sshd service; replace it.
RUN (sc query sshd >NUL 2>&1 && sc delete sshd >NUL || ver >NUL) && \
    sc create sshd binPath= "\"%OPENSSH_DIR%\sshd.exe\"" start= demand obj= LocalSystem DisplayName= "OpenSSH SSH Server" && \
    sc sidtype sshd unrestricted && \
    sc privs sshd SeAssignPrimaryTokenPrivilege/SeTcbPrivilege/SeBackupPrivilege/SeRestorePrivilege/SeImpersonatePrivilege

COPY sshd_config C:\\ProgramData\\ssh\\sshd_config
COPY start-sshd.cmd C:\\ProgramData\\ssh\\start-sshd.cmd

# The SSH users are created at run time, so OpenSSH goes on the machine PATH as well.
RUN setx /M PATH "%PATH%;%OPENSSH_DIR%;%ProgramData%\ssh"
# Set path. In nano 2019 we need to make the users environment key before we can add values to it. We dont need the call to reg.exe in 2022
RUN reg query HKCU\Environment 2> NUL || reg add HKCU\Environment /v PATH
RUN setx PATH "%OPENSSH_DIR%;%ProgramData%\ssh"

EXPOSE 22

WORKDIR C:/users/containeruser

ENTRYPOINT ["cmd", "/S", "/C"]
CMD ["start-sshd.cmd"]
