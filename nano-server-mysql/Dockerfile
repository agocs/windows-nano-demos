ARG WINDOWS_VERSION=2025
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64

# mysqld.exe and the client tools need the Visual C++ runtime. Nanoserver doesn't ship it and can't run the installer.
# Server Core doesn't ship it either, but it can run the official redistributable,
# so install it in a throwaway Server Core stage and copy the DLLs out.
FROM mcr.microsoft.com/windows/servercore:ltsc${WINDOWS_VERSION} AS vcrt
SHELL ["powershell", "-NoProfile", "-Command", "$ErrorActionPreference = 'Stop';"]
RUN curl.exe -fsSLo C:\vc_redist.x64.exe https://aka.ms/vc14/vc_redist.x64.exe; \
    $p = Start-Process C:\vc_redist.x64.exe -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru; \
    if ($p.ExitCode -notin 0, 3010) { throw ('vc_redist exited with ' + $p.ExitCode) }; \
    Remove-Item C:\vc_redist.x64.exe

FROM ${BASE_IMAGE}

# vcruntime140.dll and vcruntime140_1.dll are needed by mysqld and the client tools. msvcp140.dll by mysqld.
COPY --from=vcrt ["C:/Windows/System32/vcruntime140.dll", "C:/Windows/System32/vcruntime140_1.dll", "C:/Windows/System32/msvcp140.dll", "C:/Windows/System32/"]

# Pinned version (8.4 is the current LTS series)
ENV MYSQL_VERSION=8.4.11

# Install location. This has to be a separate ENV instruction: ENV can't reference variables set in the same instruction.
ENV MYSQL_DIR="C:\\mysql"

USER ContainerAdministrator

# Download to a file first, then extract to C:\ (the zip holds one mysql-<version>-winx64 folder).
# Unpacked it is ~1.7 GB, mostly things a server image doesn't need, so strip them in the same layer:
#  - *.pdb debug symbols (mysqld.pdb alone is 600 MB) and *.lib import libraries
#  - the debug builds of the DLLs and plugins (bin\*-debug.dll, lib\plugin\debug)
#  - the MeCab full-text parser dictionaries (lib\mecab, only used by the optional mecab plugin)
#  - C headers and docs
RUN mkdir C:\dl && \
    curl -fsSLo C:\dl\mysql.zip https://cdn.mysql.com/Downloads/MySQL-8.4/mysql-%MYSQL_VERSION%-winx64.zip && \
    tar -xf C:\dl\mysql.zip -C C:\ && \
    move C:\mysql-%MYSQL_VERSION%-winx64 %MYSQL_DIR% && \
    rmdir /s /q C:\dl && \
    del /q %MYSQL_DIR%\bin\*.pdb %MYSQL_DIR%\bin\*.lib %MYSQL_DIR%\bin\*-debug.dll && \
    rmdir /s /q %MYSQL_DIR%\lib\plugin\debug %MYSQL_DIR%\lib\mecab %MYSQL_DIR%\include %MYSQL_DIR%\docs && \
    del /q %MYSQL_DIR%\lib\*.lib

# mysqld and the client tools on the path
ENV PATH="C:\\mysql\\bin;${PATH}"

# The data directory is a volume. Folders created under C:\ inherit Modify for Authenticated Users
# (nanoserver has no icacls), so ContainerUser can write to it once it exists in the image.
RUN mkdir C:\mysql\data

COPY docker-entrypoint.cmd C:/docker-entrypoint.cmd

# mysqld runs fine as ContainerUser, so the server isn't run as an administrator
USER ContainerUser
VOLUME ["C:/mysql/data"]
EXPOSE 3306 33060

# First start initializes the data directory and sets the root password from MYSQL_ROOT_PASSWORD.
# Anything other than the default command (mysql, mysqldump, cmd, ...) is run as given.
ENTRYPOINT ["C:\\docker-entrypoint.cmd"]
CMD ["mysqld"]
