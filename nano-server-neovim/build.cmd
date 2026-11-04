@echo off
setlocal
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2025
set BASE_IMAGE_ARG=
if not "%BASE_IMAGE%"=="" set BASE_IMAGE_ARG=--build-arg BASE_IMAGE=%BASE_IMAGE%
rem Older Windows builds need older Neovim releases (see README.md): 2019 needs 0.11.2, 2022 needs 0.11.6.
set NEOVIM_VERSION_ARG=
if "%WINDOWS_VERSION%"=="2019" set NEOVIM_VERSION_ARG=--build-arg NEOVIM_VERSION=0.11.2
if "%WINDOWS_VERSION%"=="2022" set NEOVIM_VERSION_ARG=--build-arg NEOVIM_VERSION=0.11.6
rem The DLLs Neovim needs are copied from servercore inside the Dockerfile, so no host DLLs need to be staged into system32.
docker build --memory 4g --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% %NEOVIM_VERSION_ARG% -t windows-nano-neovim:%WINDOWS_VERSION% -t zippy1981/windows-nano-neovim:%WINDOWS_VERSION% .
