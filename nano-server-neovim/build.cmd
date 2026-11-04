@echo off
setlocal
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2022
set BASE_IMAGE_ARG=
if not "%BASE_IMAGE%"=="" set BASE_IMAGE_ARG=--build-arg BASE_IMAGE=%BASE_IMAGE%
rem The DLLs Neovim needs are copied from servercore inside the Dockerfile, so no host DLLs need to be staged into system32.
docker build --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% -t windows-nano-neovim:%WINDOWS_VERSION% -t zippy1981/windows-nano-neovim:%WINDOWS_VERSION% .
