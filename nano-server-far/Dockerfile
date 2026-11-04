ARG WINDOWS_VERSION=2022
# Far Manager can NOT run on nanoserver, so this image is based on servercore.
# Far.exe statically imports desktop Win32 DLLs that nanoserver doesn't ship (WINSPOOL.DRV, COMDLG32,
# SHELL32, SETUPAPI, IMM32, ...). On nanoserver ltsc2022 it exits with 0xC0000135 (STATUS_DLL_NOT_FOUND)
# before printing anything. Copying those DLLs over from servercore just changes the error to
# 0xC0000139 (STATUS_ENTRYPOINT_NOT_FOUND), because the OS DLLs depend on each other across SKUs.
ARG BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc${WINDOWS_VERSION}-amd64
FROM ${BASE_IMAGE}

# Pinned versions. FAR_BUILD/FAR_DATE identify the stable build listed on https://www.farmanager.com/download.php
ENV \
    FAR_VERSION=3.0.6699 \
    FAR_BUILD=6699 \
    FAR_DATE=20260614 \
    SEVENZIP_VERSION=26.05 \
    FAR_DIR="C:\\Program Files\\Far Manager"

SHELL ["cmd", "/S", "/C"]

# Far Manager is only published as .7z and .msi. Windows Server's tar.exe can't read Far's .7z
# ("tar: LZMA codec is unsupported" on ltsc2022), so we download the standalone 7zr.exe (a 32-bit
# binary; servercore has WoW64, nanoserver doesn't), extract with it, and delete it again.
# Far statically links the VC runtime (no vcruntime140.dll / msvcp140.dll imports), so no DLLs need staging.
RUN curl -fL -o C:\7zr.exe https://github.com/ip7z/7zip/releases/download/%SEVENZIP_VERSION%/7zr.exe && \
    curl -fL -o C:\far.7z https://www.farmanager.com/files/Far30b%FAR_BUILD%.x64.%FAR_DATE%.7z && \
    C:\7zr.exe x C:\far.7z -o"%FAR_DIR%" -y && \
    del C:\far.7z C:\7zr.exe

# servercore runs as ContainerAdministrator by default; nanoserver runs as ContainerUser.
# Switch so this image behaves like the nanoserver ones (non-admin user, PATH in that user's HKCU).
USER ContainerUser

# Add Far to the path
# The users path is empty at this point so we dont need to append
# Set path. In nano 2019 we need to make the users environment key before we can add values to it. We dont need the call to reg.exe in 2022
RUN reg query HKCU\Environment 2> NUL || reg add HKCU\Environment /v PATH
RUN setx PATH "%FAR_DIR%"

# The container has two users, ContainerAdministrator and ContainerUser.
# They don't show up in the Net User command, but they have profile directories with registry hives.
WORKDIR C:/users/containeruser

# Set the entry point and default command
ENTRYPOINT ["cmd", "/S", "/C"]
