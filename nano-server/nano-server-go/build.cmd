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
rem CGO=1 builds the cgo variant with a C toolchain (plans/go-cgo.md). It is tagged <go>-cgo-<win> and never takes the plain tags.
rem CC_TOOLCHAIN is optional; only llvm-mingw is supported.
set CGO_ARG=
set TAGS=-t windows-nano-go:%WINDOWS_VERSION% -t zippy1981/windows-nano-go:%WINDOWS_VERSION% %GO_TAGS%
if "%CGO%"=="1" (
  set CGO_ARG=--build-arg CGO=1
  if "%GO_VERSION%"=="" (
    set TAGS=-t windows-nano-go:cgo-%WINDOWS_VERSION% -t zippy1981/windows-nano-go:cgo-%WINDOWS_VERSION%
  ) else (
    set TAGS=-t windows-nano-go:%GO_VERSION%-cgo-%WINDOWS_VERSION% -t zippy1981/windows-nano-go:%GO_VERSION%-cgo-%WINDOWS_VERSION%
  )
)
if "%CGO%"=="1" if not "%CC_TOOLCHAIN%"=="" set CGO_ARG=%CGO_ARG% --build-arg CC_TOOLCHAIN=%CC_TOOLCHAIN%
docker build --memory 4g --build-arg WINDOWS_VERSION=%WINDOWS_VERSION% %BASE_IMAGE_ARG% %GO_VERSION_ARG% %CGO_ARG% %TAGS% .
