@echo off
setlocal
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2022
rem The Wine PE programs are not in git. Extract them from the pinned WineHQ .deb if wine-pe\ is empty.
dir /b "%~dp0wine-pe\*.exe" >NUL 2>&1
if errorlevel 1 (
    pwsh -NoProfile -File "%~dp0fetch-wine.ps1"
    if errorlevel 1 exit /b 1
)
set BASE_IMAGE_ARG=
if not "%BASE_IMAGE%"=="" set BASE_IMAGE_ARG=--build-arg "BASE_IMAGE=%BASE_IMAGE%"
docker build --memory 4g --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% -t windows-nano-wine-tools:%WINDOWS_VERSION% -t zippy1981/windows-nano-wine-tools:%WINDOWS_VERSION% "%~dp0."
