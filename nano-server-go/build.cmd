@echo off
setlocal
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2022
rem Go, MinGit and micro need no host DLLs. Stage any future ones into .\system32 here.
set BASE_IMAGE_ARG=
if not "%BASE_IMAGE%"=="" set BASE_IMAGE_ARG=--build-arg BASE_IMAGE=%BASE_IMAGE%
docker build --memory 4g --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% -t windows-nano-go:%WINDOWS_VERSION% -t zippy1981/windows-nano-go:%WINDOWS_VERSION% .
