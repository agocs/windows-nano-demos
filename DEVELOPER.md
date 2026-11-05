# Developer guide: finding what Nano Server is missing

Nano Server is a much smaller Windows than Server Core. Most command-line developer tools run on it, but some need DLLs, APIs or subsystems that only Server Core has. This guide explains how this repo worked out what a tool needs, what we found for each image, and when we gave up on Nano Server and used Server Core instead. Read it before adding an image, and before deciding that something "doesn't work on nanoserver".

For how images are built and tested, see the [ADRs](docs/adr/README.md), especially [0008](docs/adr/0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md) (version arguments and the matrix), [0009](docs/adr/0009-all-image-builds-use-one-reusable-workflow.md) (the shared build workflow) and [0011](docs/adr/0011-repository-conventions-are-enforced-by-tests-in-ci.md) (the convention tests). The agents that do this work are listed in [.claude/agents/README.md](.claude/agents/README.md).

## The method

We used the same loop for every tool, cheapest step first. Stop as soon as the tool works.

### 1. Run it and read the exit code

Install the tool into a throwaway Nano Server container and run something trivial, such as `--version` or `-?`. A program that can't start doesn't print anything useful, but its exit code says why. Docker prints it as a negative decimal number. Convert it to hex and look it up in Microsoft's NTSTATUS list ([MS-ERREF: NTSTATUS values](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-erref/596a1078-e883-4972-9bbc-49e60bebca55)):

| Decimal exit code | NTSTATUS | Name | Meaning |
| --- | --- | --- | --- |
| -1073741515 | `0xC0000135` | `STATUS_DLL_NOT_FOUND` | A DLL it imports doesn't exist in this image. |
| -1073741511 | `0xC0000139` | `STATUS_ENTRYPOINT_NOT_FOUND` | The DLL exists, but lacks a function the program imports. |
| -1073741502 | `0xC0000142` | `STATUS_DLL_INIT_FAILED` | A DLL loaded but its initialization failed. |

Errors from Win32 APIs, as opposed to the loader, are [system error codes](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes). For example, 1355 is `ERROR_NO_SUCH_DOMAIN`.

Test every Windows version the image targets (ADR 0008). A tool can work on ltsc2025 and fail on ltsc2019 or ltsc2022, as Neovim does.

### 2. Read the import table

When the loader can't find a DLL, the [PE import table](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format) of the executable and of each DLL it loads lists exactly what it needs. Any PE tool can show it, for example `dumpbin /imports` from the Visual C++ build tools or `llvm-objdump -p`. Compare that list with the files in `C:\Windows\System32` of the Nano Server image.

### 3. Diff Nano Server against Server Core

List `C:\Windows\System32` in both base images for the same Windows version and diff them. That shows which DLLs and programs exist only in Server Core. The ReactOS plan's audit found 251 executables in Server Core System32 that Nano Server lacks: `find`, `more`, `fc`, `where`, `whoami`, `tree`, `tasklist` and `taskkill` among them. Nano Server does have `findstr`, `sort`, `xcopy`, `reg`, `attrib`, `tar` and `curl` ([PR #9](https://github.com/zippy1981/windows-nano-demos/pull/9)).

### 4. Copy the missing pieces from a Server Core build stage

If only a few DLLs are missing, take them from a Server Core stage of the **same Windows version** and `COPY --from=` them into the Nano Server image. Never copy them from the build host. CI runs inside a container that can't see the host's files, and the host's DLLs belong to a different Windows build. Build stages are covered in [Microsoft's container base image docs](https://learn.microsoft.com/en-us/virtualization/windowscontainers/manage-containers/container-base-images). The final image is still Nano Server.

This works when the missing DLLs are self-contained. It fails when they pull in more and more of the desktop: each copied DLL needs others, and eventually `0xC0000139` shows that a core Nano Server DLL is smaller than the Server Core one the copied DLLs expect.

### 5. Probe the APIs systematically

For anything beyond one tool, the Win32 API test framework ([PR #22](https://github.com/zippy1981/windows-nano-demos/pull/22), plan in [PR #12](https://github.com/zippy1981/windows-nano-demos/pull/12)) checks three levels per image and Windows version:

- **L1:** the DLL loads
- **L2:** its exports resolve, checked against a Server Core System32 inventory
- **L3:** behaviour checks, each in a child process with a timeout

Each image and version has a committed baseline, so CI fails only when something gets worse.

### 6. Fall back to Server Core, and say why

When steps 1 to 5 don't produce a working Nano Server image, set the image's default `BASE_IMAGE` to Server Core, or override one version through `base-image-overrides` (ADR 0009). Record the exact error in a Dockerfile comment and the image README, so a later base image release can be retested.

## What we found, image by image

### Images that run on Nano Server with pieces from Server Core

| Image | Missing on Nano Server | How we found it | Fix |
| --- | --- | --- | --- |
| PHP ([README](nano-server-php/README.md)) | `vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll` | PHP and its extensions import the Visual C++ runtime. | Server Core doesn't ship it either, so a Server Core stage installs the [VC++ redistributable](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist) and the image copies the three DLLs. |
| PHP | `where.exe` | The smoke test's `where micro` failed. | `where.exe` and `en-US\where.exe.mui` are copied from the Server Core stage. |
| SSH ([README](nano-server-ssh/README.md)) | `netapi32.dll`, `whoami.exe` | `sshd.exe`, `sshd-session.exe` and `ssh.exe` exited with `0xC0000135`, and their imports include `netapi32.dll`. | Both are copied from a Server Core stage of the same version. [Win32-OpenSSH](https://github.com/PowerShell/Win32-OpenSSH) then runs, as a LocalSystem service so it can create user tokens. |
| MySQL ([draft PR #33](https://github.com/zippy1981/windows-nano-demos/pull/33)) | The same three VC++ runtime DLLs, plus `icacls.exe` | `mysqld` imports the Visual C++ runtime. The entrypoint's `icacls` call failed because Nano Server has no `icacls`. | The same Server Core redistributable stage as PHP. `icacls` turned out not to be needed, because a folder created under `C:` is already writable by ContainerUser. MySQL 8.4 runs as ContainerUser on ltsc2019, ltsc2022 and ltsc2025. |
| Caddy artifact cache ([PR #31](https://github.com/zippy1981/windows-nano-demos/pull/31)) | `certutil.exe` and `certoc.exe` | Neither exists on Nano Server ltsc2025. | The cache's root CA is imported by writing the certificate to the registry, under `HKLM\SOFTWARE\Microsoft\SystemCertificates\ROOT`. |

### Images that fell back to Server Core

| Image | What failed on Nano Server | Why we stopped |
| --- | --- | --- |
| Far Manager ([README](nano-server-far/README.md)) | `far.exe -?` exits with `0xC0000135`. Far statically imports `WINSPOOL.DRV`, `COMDLG32`, `SHELL32`, `SETUPAPI`, `IMM32`, `VERSION`, `NETAPI32` and `PSAPI`. | After copying those and their dependencies from Server Core, the error became `0xC0000139`. Nano Server's own core DLLs lack exports that the desktop DLLs need, so the copied DLLs can't run on it. The image is Server Core for every version. |
| SSH on ltsc2025 only ([README](nano-server-ssh/README.md)) | sshd runs, but every local-account logon fails in LSA: [`LsaLogonUser`](https://learn.microsoft.com/en-us/windows/win32/api/ntsecapi/nf-ntsecapi-lsalogonuser) S4U returns `0xC00000DF` (`STATUS_NO_SUCH_DOMAIN`), and `LogonUser` fails with error 1355. | The computer name and the local SAM look right, and copying the LSA-related DLLs from Server Core didn't help. ltsc2019 and ltsc2022 stay on Nano Server, and 2025 uses Server Core through `base-image-overrides`. The root cause is still unknown. |

### Version-specific findings

- **Neovim** ([PR #16](https://github.com/zippy1981/windows-nano-demos/pull/16)): on Nano Server ltsc2019, [Neovim](https://github.com/neovim/neovim/releases) 0.11.3 and later exit with `0xC0000142`. On ltsc2022, 0.11.7 and later exit with code 255 and print nothing when stdout is Docker's pipe. Both were bisected by running each release. Each Windows version is pinned to the newest release that works: 0.11.2 on 2019, 0.11.6 on 2022, and 0.12.6 on 2025.
- **32-bit programs:** Nano Server has no WoW64 layer ([WoW64 implementation details](https://learn.microsoft.com/en-us/windows/win32/winprog64/wow64-implementation-details)). On ltsc2025, `C:\Windows\SysWOW64` contains only `edit.exe`. The 32-bit [nginx for Windows](https://nginx.org/en/docs/windows.html) exits with `0xC0000135`. Copying Server Core's `SysWOW64` and `wow64*.dll` gets further, then fails at 32-bit process startup with `0xC0000481`, and importing the WoW64 registry keys is refused during the build. We stopped there and use 64-bit tools only, such as Caddy for the artifact cache.
- **Pseudo consoles:** [`CreatePseudoConsole`](https://learn.microsoft.com/en-us/windows/console/createpseudoconsole) works on Nano Server. The probe in PR #22 checks it, and the console editor plan ([PR #15](https://github.com/zippy1981/windows-nano-demos/pull/15)) relies on it.

### What the API probe found on Nano Server ltsc2025

The first baselines from [PR #22](https://github.com/zippy1981/windows-nano-demos/pull/22) list the following behaviour-level gaps. Server Core baselines have only 26 to 33 lines each.

- **DLLs that don't exist:** `avrt`, `d3d11`, `dxgi`, `gdiplus`, `hid`, `winusb`, `winscard`, `wininet`, `urlmon`, `msi`, `mscoree`, `odbc32`, `opengl32`, `riched20`, `uxtheme`, `credui`, `clbcatq`, `msvcp140`, `vcruntime140` and `windowscodecs`.
- **Present but failing:**
  - `user32`: window creation, the clipboard and `MapVirtualKey`
  - `gdi32`: `CreateCompatibleBitmap` and `CreateFontIndirectW`
  - `shell32`: `SHGetKnownFolderPath`, `ShellExecuteExW` and `SHFileOperationW`
  - `kernel32.CreateSymbolicLinkW`, `msvcrt.setlocale`, `netapi32.NetGetJoinInformation` and `pdh.PdhAddEnglishCounterW`
  - COM `CoCreateInstance` for `FileSystemObject`, `WbemLocator` and `XMLHTTPRequest`

So a tool that draws windows, uses the shell's file operations, needs MSI or .NET Framework, or talks to WMI through COM won't run on Nano Server, and copying DLLs is unlikely to fix it.

## Replacing missing programs with ReactOS or Wine builds

Two plans look at filling Nano Server's gaps with open-source builds of the missing programs, instead of with Server Core:

- **[ReactOS](https://reactos.org/)** ([plan, PR #9](https://github.com/zippy1981/windows-nano-demos/pull/9)): ReactOS releases are x86 only, which Nano Server can't run without WoW64, so the plan uses the x64 nightly builds. Those import `kernel32!__chkstk`, which Microsoft's x64 `kernel32.dll` doesn't export, so they fail with `0xC0000139`. A small shim DLL that forwards kernel32 and provides `__chkstk` made 20 of the 25 tools tried work.
- **[Wine](https://gitlab.winehq.org/wine/wine)** ([plan, PR #11](https://github.com/zippy1981/windows-nano-demos/pull/11); implementation, [PR #21](https://github.com/zippy1981/windows-nano-demos/pull/21)): Wine builds its programs as PE files, and nine of them work unmodified on every Nano Server version. A build-time import check refuses any module that needs Wine's own core DLLs or a Unix library.

## Checklist for a new image

1. Install the tool in a throwaway Nano Server container and run `--version` on 2019, 2022 and 2025. Decode any NTSTATUS exit code.
2. If a DLL is missing, read the import table and diff System32 against Server Core of the same version.
3. Copy only self-contained DLLs from a Server Core build stage of the same version. Never copy them from the host.
4. If copying turns into `0xC0000139`, or the tool needs a subsystem that isn't there (desktop UI, WoW64, LSA logon on 2025), use Server Core and record the exact error in the Dockerfile and README.
5. Write a `smoke-test.ps1` that exercises the real feature, not just `--version`, and add the image to the API probe's targets if it adds DLLs.
6. Follow the image conventions in [ADR 0008](docs/adr/0008-images-take-windows-version-defaulting-to-2025-built-as-a-matrix.md) and the [windows-demo-scaffolder agent](.claude/agents/windows-demo-scaffolder.md), and check with `uv run pytest` (ADR 0011).

## Further reading

- [Windows container base images](https://learn.microsoft.com/en-us/virtualization/windowscontainers/manage-containers/container-base-images): what Nano Server and Server Core each include.
- [Windows container version compatibility](https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/version-compatibility): which base image versions run on which hosts, under process and Hyper-V isolation.
- [Hyper-V isolation](https://learn.microsoft.com/en-us/virtualization/windowscontainers/manage-containers/hyperv-container): the default isolation on this repo's Windows 11 runner host.
- [MS-ERREF: NTSTATUS values](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-erref/596a1078-e883-4972-9bbc-49e60bebca55) and [Win32 system error codes](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes): decoding exit codes and API errors.
- [PE format](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format): import tables.
- This repo:
  - [README](README.md): the list of images
  - [ADRs](docs/adr/README.md)
  - [Patch Tuesday plan](plans/patch-tuesday-image-refresh.md)
  - each image's README under `nano-server-*/`
  - the [agents](.claude/agents/README.md)
