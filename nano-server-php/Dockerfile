ARG WINDOWS_VERSION=2022
# Use the official Microsoft Windows Server Core Nano image
FROM mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64

# Set environment variables
ENV \
    MICROEDITOR_VERSION=2.0.14 \
    MICROEDITOR_PATH="C:\\Program Files\\micro-2.0.14" \
    NODE_DIRECTORY="C:\\Program Files\\node-v22.11.0-win-x64" \
    NODE_VERSION=22.11.0 \
    PHP_VERSION=8.4.1 \
    PHP_VS_VERSION=17 \
    PHP_DIR="C:\\Program Files\\php"

# We can't install the Visual C++ Redistributable that PHP needs directly so instead we just copy the DLL
# Also in current versions of windows 11 tar.exe has been updated to support 7zip files.
# This is not the case in Server 2022 as of KB5046616 (OS Build 20348.2849)
# also we copy 7z.exe and 7z.dll to the system32 folder so we can extract the Far Manager archive
COPY system32\* C:\\windows\\system32

# Download and install nodejs We do it in two commands vecause the curl | tar -xvf - -C c:/ command doesn't extract all the files
RUN mkdir "%NODE_DIRECTORY%" && \
    curl -L https://nodejs.org/dist/v%NODE_VERSION%/node-v%NODE_VERSION%-win-x64.zip -LOJ &&\
    tar -xf node-v%NODE_VERSION%-win-x64.zip -C "%ProgramFiles%" && \
    del node-v%NODE_VERSION%-win-x64.zip

# Download PHP and extract it to C:\php using curl and tar
RUN mkdir "%PHP_DIR%" &&\
    curl -L https://windows.php.net/downloads/releases/php-%PHP_VERSION%-nts-Win32-vs%PHP_VS_VERSION%-x64.zip | tar -xf - -C "%PHP_DIR%" && \
    echo extension_dir="%PHP_DIR%\ext" >> "%PHP_DIR%\php.ini" && \
    echo extension=curl >> "%PHP_DIR%\php.ini" && \
    echo extension=fileinfo >> "%PHP_DIR%\php.ini" && \
    echo extension=openssl >> "%PHP_DIR%\php.ini" && \
    echo extension=zip >> "%PHP_DIR%\php.ini"

# Install micro editor
RUN mkdir %MICROEDITOR_PATH% &&\
    curl -LO https://github.com/zyedidia/micro/releases/download/v%MICROEDITOR_VERSION%/micro-%MICROEDITOR_VERSION%-win64.zip && \
    tar -xvf micro-%MICROEDITOR_VERSION%-win64.zip -C "%ProgramFiles%" && \
    del micro-%MICROEDITOR_VERSION%-win64.zip

# Add what we installed to the path
# The users path is empty at this point so we dont need to append
# Set path. In nano 2019 we need to make the users environment key before we can add values to it. We dont need the call to reg.exe in 2022
RUN reg query HKCU\Environment 2> NUL || reg add HKCU\Environment /v PATH
RUN setx PATH "%PHP_DIR%;%USERPROFILE%\AppData\Roaming\Composer\vendor\bin;%NODE_DIRECTORY%;%MICROEDITOR_PATH%"

# Download Composer and place composer.phar in C:\php.
# Intall the Larval tool as well. This will  create larval projects that will execute.
RUN curl https://getcomposer.org/installer | php -- --install-dir="%PHP_DIR%" && \
    echo @php "%PHP_DIR%\\composer.phar" %* > "%PHP_DIR%\\composer.bat" && \
    npm install -g npm vite && \
    composer global require laravel/installer

# The container has two users, ContainerAdministrator and ContainerUser.
# They don't show up in the Net User command, but they have profile directories with registry hives.
WORKDIR C:/users/containeruser

# Set the entry point and default command
ENTRYPOINT ["cmd", "/S", "/C"]



