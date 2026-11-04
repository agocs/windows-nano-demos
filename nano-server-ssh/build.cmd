@echo off
rem No host files need staging: the files nanoserver lacks (netapi32.dll,
rem whoami.exe) are copied from the matching servercore image in the Dockerfile.
setlocal
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2022
set BASE_IMAGE_ARG=
if not "%BASE_IMAGE%"=="" set BASE_IMAGE_ARG=--build-arg BASE_IMAGE=%BASE_IMAGE%
docker build --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% -t windows-nano-ssh:%WINDOWS_VERSION% -t zippy1981/windows-nano-ssh:%WINDOWS_VERSION% .
