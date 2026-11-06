# windows-nano-powershell: PowerShell 7 with MinGit, micro, Pester, PSScriptAnalyzer and platyPS on Nano Server.
#
# Build from this folder (build.cmd does the same, and also tags zippy1981/windows-nano-powershell):
#   docker build --memory 4g --build-arg WINDOWS_VERSION=2022 -t windows-nano-powershell:2022 .
# Each build argument is described where it is declared below.

# Windows Server LTSC version to build for: 2019, 2022 or 2025 (the default). Set with --build-arg WINDOWS_VERSION=2022.
ARG WINDOWS_VERSION=2025
# The image the final stage is built on. Defaults to Nano Server for WINDOWS_VERSION; CI pins it to a digest.
# Set with --build-arg BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc2022-amd64.
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64
FROM ${BASE_IMAGE}

# Pinned tool and module versions
ENV \
    POWERSHELL_VERSION=7.6.9 \
    POWERSHELL_DIR="C:\\Program Files\\PowerShell\\7" \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    MINGIT_VERSION=2.56.0.4 \
    MINGIT_TAG=v2.56.0.windows.4 \
    MINGIT_DIR="C:\\Program Files\\MinGit" \
    MICROEDITOR_VERSION=2.0.15 \
    MICROEDITOR_PATH="C:\\Program Files\\micro-2.0.15" \
    PESTER_VERSION=6.2.0 \
    PSSCRIPTANALYZER_VERSION=1.25.0 \
    PLATYPS_VERSION=1.0.3 \
    PSREADLINE_VERSION=2.4.5 \
    PSRESOURCEGET_VERSION=1.2.0

# Any DLLs build.cmd staged from the host. Currently only the .gitignore placeholder.
COPY system32\\* C:\\windows\\system32\\

# PowerShell 7. The zip has no top level folder so extract it straight into its own directory.
RUN mkdir "%POWERSHELL_DIR%" && \
    curl -fL --retry 5 --retry-delay 5 -o PowerShell.zip https://github.com/PowerShell/PowerShell/releases/download/v%POWERSHELL_VERSION%/PowerShell-%POWERSHELL_VERSION%-win-x64.zip && \
    tar -xf PowerShell.zip -C "%POWERSHELL_DIR%" && \
    del PowerShell.zip

# MinGit (non-busybox). Do NOT install it to "C:\Program Files\Git": MinGit's etc\gitconfig includes
# "C:/Program Files/Git/etc/gitconfig", which would then include itself and git fails with
# "exceeded maximum include depth".
RUN mkdir "%MINGIT_DIR%" && \
    curl -fL --retry 5 --retry-delay 5 -o MinGit.zip https://github.com/git-for-windows/git/releases/download/%MINGIT_TAG%/MinGit-%MINGIT_VERSION%-64-bit.zip && \
    tar -xf MinGit.zip -C "%MINGIT_DIR%" && \
    del MinGit.zip

# Install micro editor. The zip contains a micro-<version> folder.
RUN curl -fL --retry 5 --retry-delay 5 -o micro.zip https://github.com/zyedidia/micro/releases/download/v%MICROEDITOR_VERSION%/micro-%MICROEDITOR_VERSION%-win64.zip && \
    tar -xf micro.zip -C "%ProgramFiles%" && \
    del micro.zip

# Add what we installed to the path
# The users path is empty at this point so we dont need to append
# Set path. In nano 2019 we need to make the users environment key before we can add values to it. We dont need the call to reg.exe in 2022
RUN reg query HKCU\Environment 2> NUL || reg add HKCU\Environment /v PATH
RUN setx PATH "%POWERSHELL_DIR%;%MINGIT_DIR%\cmd;%MICROEDITOR_PATH%"

# Dev modules are installed for all users into C:\Program Files\PowerShell\Modules (the AllUsers
# scope, ahead of $PSHOME\Modules on PSModulePath).
# Under Hyper-V isolation pwsh crashes (exit 255, no output) as ContainerAdministrator as soon as
# PSResourceGet or PowerShellGet runs, but works as ContainerUser (the default nanoserver user).
# So ContainerAdministrator only uses cmd to let ContainerUser write that folder, ContainerUser
# saves the modules with pwsh, and afterwards the grant is removed and ownership handed back.
USER ContainerAdministrator
RUN mkdir "%ProgramFiles%\PowerShell\Modules" && \
    icacls "%ProgramFiles%\PowerShell\Modules" /grant "User Manager\ContainerUser:(OI)(CI)M"
USER ContainerUser

# From here on RUN uses PowerShell instead of cmd. Use the bare name (found via the PATH set above):
# on ltsc2019 a full "C:\Program Files\..." SHELL path is not quoted and splits at the space.
SHELL ["pwsh","-NoLogo", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# PSResourceGet fails if its LocalAppData store folder doesn't exist yet, so create it first.
# PSResourceGet itself is saved first so the pinned version is the one on PSModulePath.
RUN New-Item -ItemType Directory -Force -Path (Join-Path $env:LOCALAPPDATA 'PSResourceGet') | Out-Null; \
    $modules = Join-Path $env:ProgramFiles 'PowerShell\Modules'; \
    ([ordered]@{ \
        'Microsoft.PowerShell.PSResourceGet' = $env:PSRESOURCEGET_VERSION; \
        'Pester' = $env:PESTER_VERSION; \
        'PSScriptAnalyzer' = $env:PSSCRIPTANALYZER_VERSION; \
        'Microsoft.PowerShell.PlatyPS' = $env:PLATYPS_VERSION; \
        'PSReadLine' = $env:PSREADLINE_VERSION \
    }).GetEnumerator() | ForEach-Object { \
        Save-PSResource -Name $_.Key -Version $_.Value -Repository PSGallery -TrustRepository -IncludeXml -Path $modules \
    }; \
    Get-Module -ListAvailable Microsoft.PowerShell.PSResourceGet, Pester, PSScriptAnalyzer, Microsoft.PowerShell.PlatyPS, PSReadLine | \
        Format-Table Name, Version, ModuleBase -AutoSize

# Lock the AllUsers module folder back down to administrators
USER ContainerAdministrator
SHELL ["cmd", "/S", "/C"]
RUN icacls "%ProgramFiles%\PowerShell\Modules" /setowner Administrators /T /C /Q && \
    icacls "%ProgramFiles%\PowerShell\Modules" /remove:g "User Manager\ContainerUser"
USER ContainerUser

# The container has two users, ContainerAdministrator and ContainerUser.
# They don't show up in the Net User command, but they have profile directories with registry hives.
WORKDIR C:/users/containeruser

# Set the entry point and default command
ENTRYPOINT ["cmd", "/S", "/C"]
CMD ["pwsh"]
