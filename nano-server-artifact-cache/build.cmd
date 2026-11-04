@echo off
setlocal
rem This image is only built for nanoserver ltsc2025 (ADR 0012). Other versions are not tested.
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2025
rem Caddy is a static Go binary and needs no host DLLs, so nothing is staged into .\system32.
set BASE_IMAGE_ARG=
if not "%BASE_IMAGE%"=="" set BASE_IMAGE_ARG=--build-arg BASE_IMAGE=%BASE_IMAGE%
docker build --memory 4g --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% -t windows-nano-artifact-cache:%WINDOWS_VERSION% -t zippy1981/windows-nano-artifact-cache:%WINDOWS_VERSION% .
