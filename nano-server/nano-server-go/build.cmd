@echo off
setlocal
if "%WINDOWS_VERSION%"=="" set WINDOWS_VERSION=2025
rem Go, MinGit and micro need no host DLLs. Stage any future ones into .\system32 here.
set BASE_IMAGE_ARG=
if not "%BASE_IMAGE%"=="" set BASE_IMAGE_ARG=--build-arg BASE_IMAGE=%BASE_IMAGE%
rem GO_VERSION is optional (issue #20). Unset builds the Dockerfile's default, the newest Go.
set GO_VERSION_ARG=
set GO_TAGS=
if not "%GO_VERSION%"=="" (
  set GO_VERSION_ARG=--build-arg GO_VERSION=%GO_VERSION%
  set GO_TAGS=-t windows-nano-go:%GO_VERSION%-%WINDOWS_VERSION% -t zippy1981/windows-nano-go:%GO_VERSION%-%WINDOWS_VERSION%
)
docker build --memory 4g --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% %GO_VERSION_ARG% -t windows-nano-go:%WINDOWS_VERSION% -t zippy1981/windows-nano-go:%WINDOWS_VERSION% %GO_TAGS% .
