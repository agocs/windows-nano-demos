@echo off
setlocal
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2025
set BASE_IMAGE_ARG=
if not "%BASE_IMAGE%"=="" set BASE_IMAGE_ARG=--build-arg BASE_IMAGE=%BASE_IMAGE%
rem The DLLs Vim needs are copied from servercore inside the Dockerfile, so no host DLLs need to be staged into system32.
docker build --memory 4g --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% -t windows-nano-vim:%WINDOWS_VERSION% -t zippy1981/windows-nano-vim:%WINDOWS_VERSION% .
