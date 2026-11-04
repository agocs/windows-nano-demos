@echo off
rem No host files need staging: the files nanoserver lacks (netapi32.dll,
rem whoami.exe) are copied from the matching servercore image in the Dockerfile.
setlocal
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2022
rem Nanoserver ltsc2025 rejects local-account logons (STATUS_NO_SUCH_DOMAIN),
rem so 2025 defaults to servercore. See README.md.
if "%BASE_IMAGE%"=="" if "%WINDOWS_VERSION%"=="2025" set BASE_IMAGE=mcr.microsoft.com/windows/servercore:ltsc2025-amd64
set BASE_IMAGE_ARG=
if not "%BASE_IMAGE%"=="" set BASE_IMAGE_ARG=--build-arg BASE_IMAGE=%BASE_IMAGE%
docker build --memory 4g --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% -t windows-nano-ssh:%WINDOWS_VERSION% -t zippy1981/windows-nano-ssh:%WINDOWS_VERSION% .
