@echo off
setlocal
rem WINDOWS_VERSION picks the LTSC base: 2019, 2022 (default) or 2025.
rem BASE_IMAGE optionally overrides the nanoserver base image entirely.
if not defined WINDOWS_VERSION set "WINDOWS_VERSION=2025"
set "BUILD_ARGS=--build-arg WINDOWS_VERSION=%WINDOWS_VERSION%"
if defined BASE_IMAGE set "BUILD_ARGS=%BUILD_ARGS% --build-arg BASE_IMAGE=%BASE_IMAGE%"
docker build %BUILD_ARGS% -t windows-nano-php:%WINDOWS_VERSION% -t zippy1981/windows-nano-php:%WINDOWS_VERSION% "%~dp0."
