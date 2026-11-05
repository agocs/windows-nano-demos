# Far Manager 3 Windows container

[Far Manager](https://www.farmanager.com/) 3.0 build 6699 x64 (the current stable build) in a Windows container, on the `PATH` as `far`.

**This image is based on Windows Server Core, not Nano Server.** It lives under `server-core/` and is published as `zippy1981/windows-servercore-far`. Far needs desktop Win32 DLLs that Nano Server doesn't have, so the image is a lot bigger than the other ones here. See [Why not nanoserver](#why-not-nanoserver).

## Building

To build a 2025 container, the default:

```cmd
build.cmd
```

To build the Windows 2019 or 2025 container, from PowerShell:

```pwsh
$env:WINDOWS_VERSION=2019
./build.cmd
```

From the Command Prompt:

```cmd
set WINDOWS_VERSION=2019
build.cmd
```

`build.cmd` also passes `BASE_IMAGE` through to `docker build` when it's set. The default is `mcr.microsoft.com/windows/servercore:ltsc%WINDOWS_VERSION%-amd64`.

There are no host DLLs to stage. Far links the C runtime statically, so it doesn't need `vcruntime140.dll`. Far ships only as `.7z` and `.msi`, and Windows Server's `tar.exe` can't unpack the `.7z` (`tar: LZMA codec is unsupported`). So the Dockerfile downloads the standalone `7zr.exe` 26.05 from the 7-Zip GitHub releases, extracts Far with it, and then deletes it. Unlike `nano-server/nano-server-php`, you don't need 7-Zip installed on the host.

## Running

Far is a full-screen console app, so give it a TTY:

```cmd
docker run -it --rm windows-servercore-far:2022 far
```

Press F10 to quit. Far keeps its settings in `C:\Users\ContainerUser\AppData\Roaming\Far Manager\Profile`, and they're lost when the container is removed. To keep them, mount a volume there.

## Testing

Two tests, both run in CI by [`.github/workflows/far-manager.yml`](../../.github/workflows/far-manager.yml) for ltsc2019, ltsc2022 and ltsc2025:

1. **It loads.** `docker run --rm windows-servercore-far:2022 "far.exe -?"` prints the usage text (`Far Manager, version 3.0.6699.0 x64` ...) and exits with 0. This works with or without `-t`.
2. **It really runs.** The [`test`](test) folder is copied into a created container with `docker cp`, so no bind mount is needed. The container is then started with `-t`, and the steps are:
    1. [`run-test.cmd`](test/run-test.cmd) starts `far.exe -s <test profile> -set:Confirmations.Exit=false`.
    2. The profile has a LuaMacro [autorun macro](test/profile/Macros/scripts/autotest.lua) (`flags = "RunAfterFARStart"`). It writes Far's version, PID, console size and active panel to `macro.txt`.
    3. The macro types `echo far_cmdline_ok FARHOME=%FARHOME%> ...\cmd.txt` into Far's command line, presses Enter, then presses F10.
    4. `run-test.cmd` checks that Far exited with 0 and that both files exist with the expected contents, then prints `PASS`.

To run the second test by hand:

```pwsh
docker create -t --name far-test windows-servercore-far:2022 "C:\Users\ContainerUser\far-test\run-test.cmd"
docker cp test "far-test:C:\Users\ContainerUser\far-test"
docker start -a far-test
docker inspect -f '{{.State.ExitCode}}' far-test
docker rm far-test
```

Output on ltsc2022 (process and hyperv isolation), after Far's screen output:

```text
===== far-test results =====
FAR_EXIT=0
far_version=3.0.0.6699.0
far_pid=1824
console=80x25
active_panel=C:\Program Files\Far Manager
panel_items=41
far_cmdline_ok FARHOME=C:\Program Files\Far Manager
PASS
```

## What works and what doesn't

- Works: Far starts, draws its panels, loads plugins and runs Lua macros. It runs commands from its command line and quits cleanly with exit code 0, under both process and hyperv isolation on ltsc2022.
- Works: `far.exe -?` writes the help text to stdout even without a TTY.
- Doesn't work: running Far without `-t`/`-it`. It's an interactive console UI.
- Doesn't work: Nano Server (see below).
- Untested: anything that needs a GUI or clipboard, network panels, and the NetBox plugin.

## Why not nanoserver

Far.exe statically imports `WINSPOOL.DRV`, `COMDLG32.dll`, `SHELL32.dll`, `SETUPAPI.dll`, `IMM32.dll` and other desktop DLLs. On `nanoserver:ltsc2022`, `far.exe -?` exits with `0xC0000135` (`STATUS_DLL_NOT_FOUND`) before printing anything. Copying those DLLs over from Server Core doesn't fix it either. The error changes to `0xC0000139` (`STATUS_ENTRYPOINT_NOT_FOUND`), because the OS DLLs depend on each other in ways that don't carry across SKUs. Nano Server also can't run the 32-bit `7zr.exe`, since it has no WoW64.
