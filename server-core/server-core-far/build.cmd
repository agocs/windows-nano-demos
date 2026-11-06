@echo off
setlocal
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2025
rem Far Manager statically links the VC runtime, so unlike nano-server/nano-server-php there are no host DLLs to stage into system32.
rem The .7z is extracted with a downloaded 7zr.exe inside the build instead of with a host copy of 7z.exe.
set BASE_IMAGE_ARG=
if not "%BASE_IMAGE%"=="" set BASE_IMAGE_ARG=--build-arg "BASE_IMAGE=%BASE_IMAGE%"
rem Hyper-V isolated builds default to a 1 GB memory limit and can hang, so give them 4 GB.
docker build --memory 4g --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% -t windows-servercore-far:%WINDOWS_VERSION% -t zippy1981/windows-servercore-far:%WINDOWS_VERSION% "%~dp0."
