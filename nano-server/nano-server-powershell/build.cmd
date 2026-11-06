@echo off
setlocal
pushd "%~dp0"
REM --memory 4g: Hyper-V isolated builds default to 1 GB and can hang.
REM Stage any host DLLs the image needs into .\system32 here. PowerShell, MinGit and micro currently need none.
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2025
set BASE_IMAGE_ARG=
if not "%BASE_IMAGE%"=="" set BASE_IMAGE_ARG=--build-arg "BASE_IMAGE=%BASE_IMAGE%"
docker build --memory 4g --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% -t windows-nano-powershell:%WINDOWS_VERSION% -t zippy1981/windows-nano-powershell:%WINDOWS_VERSION% .
set BUILD_RESULT=%ERRORLEVEL%
popd
exit /b %BUILD_RESULT%
