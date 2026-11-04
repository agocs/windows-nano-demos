@echo off
rem Builds the probe layer on top of one target for a local run.
rem   set TARGET=nanoserver & set WINDOWS_VERSION=2022 & build.cmd
rem Needs bin\apiprobe.exe (from the CI artifact "apiprobe", or make -C src on Linux/WSL).
setlocal
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2022
if "%TARGET%"=="" set TARGET=nanoserver
if not exist bin\apiprobe.exe (
  echo bin\apiprobe.exe is missing: download the apiprobe artifact or run make -C src
  exit /b 1
)
for /f "usebackq delims=" %%i in (`pwsh -NoProfile -Command "(./scripts/Resolve-Target.ps1 -Name %TARGET% -WindowsVersion %WINDOWS_VERSION%).BaseImage"`) do set BASE_IMAGE=%%i
if "%BASE_IMAGE%"=="" (
  echo target %TARGET% is not available
  exit /b 1
)
docker build --memory 4g --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% --build-arg BASE_IMAGE=%BASE_IMAGE% -t api-probe:%TARGET%-%WINDOWS_VERSION% .
