@echo off
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2025
set BASE_IMAGE_ARG=
if not "%BASE_IMAGE%"=="" set BASE_IMAGE_ARG=--build-arg BASE_IMAGE=%BASE_IMAGE%
docker build --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% -t windows-nano-gh-runner:%WINDOWS_VERSION% -t zippy1981/windows-nano-gh-runner:%WINDOWS_VERSION% .
