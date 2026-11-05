# windows-nano-php: PHP 8.5 and Node.js with Composer, the Laravel installer, vite and the micro editor on Nano Server.
#
# Build from this folder (build.cmd does the same, and also tags zippy1981/windows-nano-php):
#   docker build --memory 4g --build-arg WINDOWS_VERSION=2022 -t windows-nano-php:2022 .
# Each build argument is described where it is declared below.

# Windows Server LTSC version to build for: 2019, 2022 or 2025 (the default). Set with --build-arg WINDOWS_VERSION=2022.
ARG WINDOWS_VERSION=2025
# The image the final stage is built on. Defaults to Nano Server for WINDOWS_VERSION; CI pins it to a digest.
# Set with --build-arg BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc2022-amd64.
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64

# PHP needs the Visual C++ runtime. Nanoserver doesn't ship it and can't run the installer.
# Server Core doesn't ship it either, but it can run the official redistributable,
# so install it in a throwaway Server Core stage and copy the DLLs out.
FROM mcr.microsoft.com/windows/servercore:ltsc${WINDOWS_VERSION} AS vcrt
SHELL ["powershell", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop';"]
RUN curl.exe -fsSLo C:\vc_redist.x64.exe https://aka.ms/vc14/vc_redist.x64.exe; \
    $p = Start-Process C:\vc_redist.x64.exe -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru; \
    if ($p.ExitCode -notin 0, 3010) { throw ('vc_redist exited with ' + $p.ExitCode) }; \
    Remove-Item C:\vc_redist.x64.exe

FROM ${BASE_IMAGE}

# vcruntime140.dll is needed by php.exe and every extension.
# vcruntime140_1.dll and msvcp140.dll are needed by the ICU DLLs (intl) and a few other extensions.
COPY --from=vcrt ["C:/Windows/System32/vcruntime140.dll", "C:/Windows/System32/vcruntime140_1.dll", "C:/Windows/System32/msvcp140.dll", "C:/Windows/System32/"]
# Nanoserver has no where.exe. Server Core's copy only needs DLLs nanoserver already has.
COPY --from=vcrt ["C:/Windows/System32/where.exe", "C:/Windows/System32/"]
COPY --from=vcrt ["C:/Windows/System32/en-US/where.exe.mui", "C:/Windows/System32/en-US/"]

# Pinned versions
ENV \
    MICROEDITOR_VERSION=2.0.15 \
    NODE_VERSION=26.13.0 \
    NPM_VERSION=12.2.1 \
    PHP_VERSION=8.5.12-1 \
    PHP_VS_VERSION=17

# Install locations derived from the versions above.
# This has to be a separate ENV instruction: ENV can't reference variables set in the same instruction.
ENV \
    MICROEDITOR_PATH="C:\\Program Files\\micro-${MICROEDITOR_VERSION}" \
    NODE_DIRECTORY="C:\\Program Files\\node-v${NODE_VERSION}-win-x64" \
    PHP_DIR="C:\\Program Files\\php"

# Download and install nodejs. We do it in two commands because the curl | tar -xf - -C c:/ command doesn't extract all the files
RUN mkdir "%NODE_DIRECTORY%" && \
    curl -fLOJ https://nodejs.org/dist/v%NODE_VERSION%/node-v%NODE_VERSION%-win-x64.zip && \
    tar -xf node-v%NODE_VERSION%-win-x64.zip -C "%ProgramFiles%" && \
    del node-v%NODE_VERSION%-win-x64.zip

# Download PHP and extract it to %PHP_DIR% using curl and tar
# Use the archives path: it keeps every release, while /releases/ only has the latest patch of each branch
# Download to a file first: piping the zip into tar silently skips entries (it dropped brotlicommon.dll, which php_curl.dll needs)
# The last command fails the build if any of the enabled extensions doesn't load
RUN mkdir "%PHP_DIR%" && \
    curl -fLo php.zip https://windows.php.net/downloads/releases/archives/php-%PHP_VERSION%-nts-Win32-vs%PHP_VS_VERSION%-x64.zip && \
    tar -xf php.zip -C "%PHP_DIR%" && \
    del php.zip && \
    echo extension_dir="%PHP_DIR%\ext" >> "%PHP_DIR%\php.ini" && \
    echo extension=curl >> "%PHP_DIR%\php.ini" && \
    echo extension=fileinfo >> "%PHP_DIR%\php.ini" && \
    echo extension=openssl >> "%PHP_DIR%\php.ini" && \
    echo extension=zip >> "%PHP_DIR%\php.ini" && \
    "%PHP_DIR%\php.exe" -r "exit(count(array_diff(['curl', 'fileinfo', 'openssl', 'zip'], get_loaded_extensions())));"

# Install micro editor. The zip holds a micro-<version> folder, which becomes %MICROEDITOR_PATH%
RUN mkdir "%MICROEDITOR_PATH%" && \
    curl -fLO https://github.com/micro-editor/micro/releases/download/v%MICROEDITOR_VERSION%/micro-%MICROEDITOR_VERSION%-win64.zip && \
    tar -xf micro-%MICROEDITOR_VERSION%-win64.zip -C "%ProgramFiles%" && \
    del micro-%MICROEDITOR_VERSION%-win64.zip

# Add what we installed to the path
# The users path is empty at this point so we dont need to append
# In nano 2019 we need to make the users environment key before we can add values to it. We dont need the call to reg.exe in 2022 and later
RUN reg query HKCU\Environment 2> NUL || reg add HKCU\Environment /v PATH
RUN setx PATH "%PHP_DIR%;%USERPROFILE%\AppData\Roaming\Composer\vendor\bin;%NODE_DIRECTORY%;%MICROEDITOR_PATH%"

# Download Composer and place composer.phar in %PHP_DIR%.
# Install the Laravel installer as well. It creates Laravel projects that will execute.
# npm is pinned so a new npm major can't drop support for the pinned Node version.
RUN curl -fsSL https://getcomposer.org/installer | php -- --install-dir="%PHP_DIR%" && \
    echo @php "%PHP_DIR%\\composer.phar" %* > "%PHP_DIR%\\composer.bat" && \
    npm install -g npm@%NPM_VERSION% vite && \
    composer global require laravel/installer

# The container has two users, ContainerAdministrator and ContainerUser.
# They don't show up in the Net User command, but they have profile directories with registry hives.
WORKDIR C:/users/containeruser

# Set the entry point and default command
ENTRYPOINT ["cmd", "/S", "/C"]

