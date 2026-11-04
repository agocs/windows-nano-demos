# Nanoserver with Wine's command-line tools

This image adds console tools that nanoserver lacks: `find`, `fc`, `where`, `whoami`, `tasklist`, `taskkill`, `start`, `cabarc` and `fsutil`. They are the **unmodified** x86_64 PE programs from WineHQ's `wine-stable` 11.0 package for Ubuntu 24.04 (noble). Wine builds every module as a real PE file, and these programs only import DLLs that nanoserver already has, so they run on real Windows without Wine itself.

See [`plans/wine-binaries.md`](../plans/wine-binaries.md) for the design, and [`SOURCE.md`](SOURCE.md) for where the binaries and their source come from.

## Build

```cmd
set WINDOWS_VERSION=2022
build.cmd
```

`WINDOWS_VERSION` is `2019`, `2022` or `2025`. The Wine programs are not in git. If `wine-pe\` is empty, `build.cmd` runs `fetch-wine.ps1`, which downloads the pinned `.deb`, checks its SHA-256 and extracts only the files listed in `tools.txt` with Windows 11's built-in `tar.exe`. It needs pwsh 7.

In CI, the `extract-wine` job on `ubuntu-latest` does the same with `dpkg-deb` (`extract-wine.sh`) and passes the files to the Windows jobs as an artifact.

The image is tagged `windows-nano-wine-tools:<version>` and `zippy1981/windows-nano-wine-tools:<version>`.

## What is safe to copy

Only modules that pass all three checks are copied:

1. Not a Wine core module (`ntdll`, `kernel32`, `kernelbase`, `user32`, `gdi32`, `advapi32`, `ws2_32`, `msvcrt`, `ucrtbase` and others). Both extract scripts refuse these names.
2. No unixlib. If `lib/wine/x86_64-unix/<name>.so` exists, the PE half needs the Unix side, and the extract scripts refuse it.
3. Every import resolves against the base image. The Dockerfile's `check` stage runs `scripts/Test-PeImports.ps1` inside the exact nanoserver base, and the build fails on any missing DLL, function name or ordinal.

Phase 1 ships only `.exe` programs, and no Wine DLLs at all.

## Use

The tools are in `C:\Program Files\wine-tools`, which is appended to the user `PATH` after the system `PATH`, so nothing that nanoserver ships is shadowed. `WINEDEBUG=-all` is set in the image. Without it, Wine's stub code paths print `fixme:` lines to stderr.

```cmd
docker run --rm windows-nano-wine-tools:2022 "whoami & where cmd & tasklist"
```

`start` is also a `cmd` built-in, and the built-in wins. Even `start.exe` does not help, because `cmd` parses it as the built-in `start` followed by `.exe`. Call Wine's program by its full path, `"C:\Program Files\wine-tools\start.exe"`, or from a program that is not `cmd`.

Wine's `whoami` ends its output with a bare LF, so `findstr`'s `$` anchor (which needs a CR) does not match it.

## Experiments that are not in the image

These were tried on ltsc2022 with the unmodified Wine 11.0 files, and are not shipped:

- `timeout.exe`: with `docker run -t` it counts down and returns. Without a console it prints `ERROR: not possible to redirect input`, so it is useless in scripts and CI.
- `cscript.exe` with app-local `jscript.dll`, `vbscript.dll` and `scrrun.dll`: all their imports resolve, but `regsvr32` fails (`DllRegisterServer` returns `0x80004002`). With the COM classes and the `.js` association added to the registry by hand, `cscript` still prints `Could not create script engine`.

## Tests

`C:\tests\run-tests.cmd` is baked into the image. It prints [TAP](https://testanything.org/) and exits with the number of failures. The checks use only `cmd` built-ins and nanoserver's own `findstr`, so a broken Wine tool cannot hide its own failure.

```cmd
docker run --rm windows-nano-wine-tools:2022 C:\tests\run-tests.cmd
```

| # | What is tested |
| --- | --- |
| 1-3 | `find` in a file, `find /c`, and `find` reading stdin |
| 4-5 | `fc` on different files (exit code 1) and identical files (exit code 0) |
| 6-7 | `where cmd`, and `where /q` on a missing tool (exit code 1) |
| 8 | `whoami` prints `User Manager\ContainerUser` |
| 9-10 | `tasklist` and `tasklist /fi "imagename eq cmd.exe"` |
| 11 | `taskkill /?` |
| 12 | `start.exe /b /wait cmd /c exit 3` passes the exit code back |
| 13 | `cabarc n` creates a cabinet and `cabarc l` lists it |
| 14 | `fsutil hardlink create`, and the link has the file's content |
| 15 | Every tool in `tools.txt` loads (no 0xC0000135, 0xC0000139 or 0xC0000005) |
| 16 | `tasklist` prints `fixme` without `WINEDEBUG`, and nothing with `WINEDEBUG=-all` |

## Limits

Wine's programs are partial reimplementations. Only the switches above are tested. `fsutil` implements only `hardlink`. Tools that nanoserver already has (`xcopy`, `sort`, `findstr`, `reg`, `attrib`, `hostname` and others) are not shipped, and neither are Wine's stubs (`robocopy`, `icacls`, `certutil` and others) or programs that do not load on nanoserver (`cmd`, `expand`, `net`). The plan lists the reasons.

## License

Wine is licensed under the LGPL, version 2.1 or later. `COPYING.LIB`, `LICENSE`, `AUTHORS` and `SOURCE.md` are copied next to the tools in the image. `SOURCE.md` names the exact `.deb` and the matching source tarball with their SHA-256 hashes.
