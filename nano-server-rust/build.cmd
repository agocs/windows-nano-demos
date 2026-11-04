@echo off
rem The gnu Rust toolchain, MinGit and micro are self-contained, so no host DLLs need to be staged in system32 right now.
rem Copy any host DLLs the image needs into .\system32 here.
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2022
rem BASE_IMAGE is optional. When unset the Dockerfile uses nanoserver:ltsc%WINDOWS_VERSION%-amd64.
set BASE_IMAGE_ARG=
if not "%BASE_IMAGE%"=="" set BASE_IMAGE_ARG=--build-arg BASE_IMAGE=%BASE_IMAGE%
docker build --memory 4g --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% -t windows-nano-rust:%WINDOWS_VERSION% -t zippy1981/windows-nano-rust:%WINDOWS_VERSION% .
