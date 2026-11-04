# Plan: nanoserver image with ReactOS command-line tools

## Goal

Build a nanoserver image variant, `nano-server-reactos-tools/`, that adds the console tools developers expect from full Windows but that nanoserver does not ship (`find`, `more`, `fc`, `where`, `whoami`, `tree`, `tasklist`, `taskkill` and others). The binaries come from ReactOS amd64 builds. Every tool must run on real NT (Windows Server 2019, 2022 and 2025 nanoserver) and produce the output a test expects.

This plan is based on an audit and a prototype that were run on the host (Windows 11 build 26300, nanoserver `ltsc2022` 10.0.20348.5773, process isolation). The prototype results are in [Prototype results](#prototype-results).

## Summary of decisions

- **Source:** the ReactOS **nightly x64 MSVC boot CD** from `https://iso.reactos.org/bootcd/`. ReactOS releases (0.4.16 and older) are x86 only, and nanoserver has no WoW64, so 32-bit binaries cannot run. The build is pinned by revision and SHA-256.
- **The blocker:** ReactOS x64 MSVC binaries import `__chkstk` from `kernel32.dll`. Microsoft's x64 `kernel32.dll` does not export `__chkstk` (it lives in `ntdll.dll`). Every tool that has a stack frame over 4 KiB fails to load with `STATUS_ENTRYPOINT_NOT_FOUND` (0xC0000139, exit code -1073741511).
- **The fix (prototype works):** a shim DLL, `rosk32sh.dll`, that forwards every `kernel32` export the tools use to the real `kernel32` and implements `__chkstk` itself. The import descriptor name `kernel32.dll` in each tool is rewritten in place to `rosk32sh.dll` (same length, 12 characters). With the shim, 20 of the 25 tools tried run correctly.
- **Install location:** `C:\Program Files\reactos-tools`, appended to the end of `PATH`. Nothing goes into `C:\Windows\System32`, and no ReactOS core DLL (`ntdll`, `kernel32`, `kernelbase`, `user32`, `msvcrt`, `advapi32` and the rest) is ever copied into the image.
- **Licensing:** GPL-2.0-or-later (some LGPL-2.1 files that come from Wine). Pushing the image to Docker Hub distributes the binaries, so the image ships the license text, the exact source commit, and the patch tooling. The source archive is published as a GitHub release asset next to each image tag.

## Audit: what nanoserver lacks compared with servercore

The audit was run on `ltsc2022` with `dir /a-d /b C:\Windows\System32`.

- Servercore `System32` has 321 `.exe`/`.com` files. **251 of them are not in nanoserver.** Nanoserver has 70 executables.
- Servercore `System32` has 1,398 DLLs. 1,102 of them are not present in nanoserver as real files (API-set and `ext-ms-*` stubs excluded).
- In nanoserver, `kernel32.dll`, `advapi32.dll`, `user32.dll`, `gdi32.dll`, `shell32.dll`, `ole32.dll`, `shlwapi.dll`, `version.dll`, `winmm.dll`, `comctl32.dll`, `setupapi.dll` and others are **reverse forwarders** in `C:\Windows\System32\forwarders\`. They load, but many exports forward to API sets that nanoserver does not implement.

### Developer tools nanoserver already has

These do not need ReactOS versions, and the image must not shadow them: `attrib`, `cmd`, `curl`, `expand`, `findstr`, `hostname`, `icacls`, `ipconfig`, `net`, `netsh`, `netstat`, `ping`, `reg`, `regsvr32`, `sc`, `schtasks`, `setx`, `sort`, `tar`, `tracert`, `xcopy`.

### Developer tools that servercore has and nanoserver lacks

`cacls`, `certutil`, `chcp.com`, `choice`, `cipher`, `clip`, `comp`, `compact`, `cscript`/`wscript`, `doskey`, `fc`, `find`, `forfiles`, `fsutil`, `ftp`, `help`, `label`, `makecab`, `mode.com`, `more.com`, `msiexec`, `nslookup`, `print`, `replace`, `robocopy`, `runas`, `rundll32`, `shutdown`, `subst`, `systeminfo`, `takeown`, `taskkill`, `tasklist`, `timeout`, `tree.com`, `waitfor`, `where`, `whoami`.

### DLLs that do not load at all in nanoserver

Probed with `regsvr32 /s <dll>` (exit code 3 means `LoadLibrary` failed): `avrt`, `clbcatq`, `credui`, `d3d11`, `dsound`, `dxgi`, `framedynos`, `fsutilext`, `gdiplus`, `hid`, `mscoree`, `msi`, `msvcp140`, `nddeapi`, `netapi32`, `odbc32`, `opengl32`, `riched20`, `urlmon`, `uxtheme`, `vcruntime140`, `windowscodecs`, `winscard`, `winsta`, `winusb`, `wininet`.

Tools that need any of these (`net.exe` from ReactOS needs `netapi32`, `msiexec` needs `msi`) cannot work without bringing in that DLL too. That is out of scope for phase 1.

## Source: ReactOS nightly boot CD

- Index: <https://iso.reactos.org/bootcd/> (nightlies, built on every commit to `master`, see <https://reactos.org/getbuilds/>).
- File pattern: `reactos-bootcd-<version>-<revision>-x64-msvc-win-dbg.7z`. x64 builds come from MSVC only, as debug builds. There is no x64 GCC or release nightly.
- Pinned build for phase 1 (prototype): `reactos-bootcd-0.4.17-dev-1302-ge25c373-x64-msvc-win-dbg.7z`
  - URL: `https://iso.reactos.org/bootcd/reactos-bootcd-0.4.17-dev-1302-ge25c373-x64-msvc-win-dbg.7z`
  - Size: 87,401,761 bytes
  - SHA-256: `AFA7B62A626C440874FF04D51EBA5C5B2AB357E79A7BD467BE47D6F8F4D0D59A`
  - Source commit: `e25c37366b65d94985522a931f76351d6b244234` in <https://github.com/reactos/reactos>
- Layout: the `.7z` holds one `.iso`. The ISO has a live tree, so the binaries are plain files in `reactos\system32\` (797 files). There is no need to unpack `amd64\reactos.cab`.
- Nightlies are not kept forever. In phase 1, upload the pinned `.7z` as a GitHub release asset in this repo (release `reactos-bootcd-0.4.17-dev-1302`) and make the Dockerfile download from there, with `iso.reactos.org` as the documented upstream.

Release builds cannot be used: <https://reactos.org/download/> and <https://github.com/reactos/reactos/releases> only offer x86 ISOs (for example `ReactOS-0.4.16-i386.zip`).

### Extraction tools

The nanoserver `ltsc2022` `tar.exe` cannot read `.7z` or `.iso` (see the comment in `nano-server-php/Dockerfile`). Use 7-Zip in the builder stage:

1. `7zr.exe` (standalone, `.7z` only): `https://www.7-zip.org/a/7zr.exe`
2. The 7-Zip x64 installer is a 7z SFX archive. `7zr x` unpacks it and gives `7z.exe` and `7z.dll`, which read ISO: `https://github.com/ip7z/7zip/releases/download/26.05/7z2605-x64.exe` (7-Zip 26.05, 2026-10-21).
3. PowerShell 7 for hashing and patching (nanoserver has no `certutil` and no PowerShell): `https://github.com/PowerShell/PowerShell/releases/download/v7.6.9/PowerShell-7.6.9-win-x64.zip`

## The ABI problem and the shim

### What breaks

Static analysis of every tool's import table against the exports of nanoserver's DLLs showed that 37 of the 44 tools tried import `kernel32.dll!__chkstk`. On x64 Windows `__chkstk` is exported only by `ntdll.dll`. ReactOS's own x64 `kernel32` exports it, so ReactOS MSVC builds link against it. The Windows loader fails the process before `main` runs.

All the other `kernel32`, `msvcrt` and `advapi32` imports of the chosen tools resolve against nanoserver's forwarders, `KernelBase.dll`, `kernel32legacy.dll` and `msvcrt.dll`.

Other problems, each confined to one tool:

| Tool | Missing | Result |
| --- | --- | --- |
| `reg.exe` | `advapi32_vista.dll` (a ReactOS-only DLL) | `STATUS_DLL_NOT_FOUND`; nanoserver has its own `reg.exe`, so skip |
| `net.exe` | `netapi32.dll`, `mpr.dll` | `STATUS_DLL_NOT_FOUND`; nanoserver has its own `net.exe`, so skip |
| `msiexec.exe` | `msi.dll` | Skip |
| `expand.exe` | `setupapi!SetupIterateCabinetA` and `SetupGetFileCompressionInfoExA` | Skip; nanoserver has `expand.exe` |
| `chkdsk.exe`, `format.com` | `fmifs.dll` (ReactOS-only) | Skip, not useful in a container |
| `cscript.exe` | Access violation at start (0xC0000005) | Skip in phase 1; look at it in phase 3 |

### The shim, `rosk32sh.dll`

- A DLL whose export table is generated from the union of the `kernel32.dll` imports of every tool in the image (210 names for the prototype set).
- Each export except `__chkstk` is a forwarder, for example `HeapAlloc = kernel32.HeapAlloc`. The real `kernel32` forwarder then sends it on to the API sets.
- `__chkstk` is implemented in the shim with the standard x64 stack-probe routine. `RAX` holds the size. It touches each 4 KiB page and keeps every register except flags. This matches the MSVC contract, because the caller does the `sub rsp, rax` itself.
- Each tool's import descriptor whose name is `kernel32.dll` (matched without regard to case, exact length) is rewritten in place to `rosk32sh.dll`. The PE checksum is set to zero. No section sizes change.
- The prototype linked the shim with the Rust `x86_64-pc-windows-gnu` toolchain (`rust-lld` in mingw mode accepts a `.def` file with forwarders) as a `#![no_std]` `cdylib` with `global_asm!`. The implementing agent may use llvm-mingw instead (`https://github.com/mstorsjo/llvm-mingw/releases/download/20261020/llvm-mingw-20261020-ucrt-x86_64.zip`, `x86_64-w64-mingw32-clang -shared -nostdlib -Wl,--entry,DllMain chkstk.S rosk32sh.def`), but must then check that the export table is the same.
- Simpler option for the implementing agent to test: forward `__chkstk = ntdll.__chkstk` instead of implementing it. This was not tested properly, because the prototype test that tried it had only patched two binaries. Keep the asm version unless the forwarder version passes the full test suite on all three Windows versions.

Reference code for the prototype is in [Appendix: prototype code](#appendix-prototype-code).

## Which binaries to ship

### Tier 1: ship and test (they worked in the prototype with the shim)

| Tool | Prototype result on ltsc2022 |
| --- | --- |
| `find.exe` | `find "one" a.txt` prints `---------- A.TXT` and `one` |
| `more.com` | Pipes through when stdout is not a console |
| `fc.exe` | Prints `Comparing files a.txt and b.txt`, exit code 1 when files differ |
| `where.exe` | `where cmd` prints `C:\Windows\system32\cmd.exe` |
| `whoami.exe` | Prints `user manager\containeruser` |
| `tree.com` | Prints `Folder PATH Listing` and the volume serial number |
| `comp.exe` | `Files compare OK` for identical files |
| `tasklist.exe` | Prints the process table header and rows |
| `taskkill.exe` | `/?` prints usage |
| `chcp.com` | `Active code page: 65001` |
| `mode.com` | `mode con` prints `Status for device CON:` |
| `help.exe` | `help dir` prints the `DIR` help text |
| `replace.exe` | `/?` prints usage |
| `doskey.exe` | Runs (no `__chkstk` import) |
| `cacls.exe` | Lists ACLs (no `__chkstk` import) |
| `fsutil.exe` | `fsutil fsinfo drives` prints `Drives: C:\` |
| `nslookup.exe` | `nslookup localhost` resolves `127.0.0.1` |
| `whois.exe`, `ftp.exe` | Start and print usage |
| `subst.exe` | Prototype run was lost to a Docker HCS timeout; retest |

### Tier 2: ship only if a test passes on all three versions

- `timeout.exe`: fails with `The handle is invalid` when stdin is not a console. Test it with `docker run -t`. If it still fails, leave it out.
- `label.exe`, `shutdown.exe`, `runas.exe`, `logoff.exe`, `eventcreate.exe`: they start and print `/?` help. Their real actions need services nanoserver does not run. Ship them only if the user asks.
- `certutil.exe`: starts, but `-hashfile` fails with error 234. Leave it out until fixed.
- `clip.exe`: starts, but prints `This function is not supported on this system` (no clipboard in nanoserver). Leave it out.

### Never ship

ReactOS core DLLs (`ntdll`, `kernel32`, `kernelbase`, `user32`, `gdi32`, `msvcrt`, `advapi32`, `rpcrt4`, `combase`, `ole32`, `shell32`), drivers, `cmd.exe` (nanoserver's own `cmd` is better and other images depend on it), and any GUI program (`notepad`, `regedit`, `taskmgr`, `explorer`).

## Image layout

- Folder: `nano-server-reactos-tools/`
- Image: `windows-nano-reactos-tools:<WINDOWS_VERSION>` and `zippy1981/windows-nano-reactos-tools:<WINDOWS_VERSION>`
- Files:
  - `nano-server-reactos-tools/Dockerfile`
  - `nano-server-reactos-tools/build.cmd` (same pattern as `nano-server-php/build.cmd`, but no host DLL copying)
  - `nano-server-reactos-tools/README.md`
  - `nano-server-reactos-tools/tools.txt`: one file name per line, the tier 1 list. The builder reads it, so adding a tool is a one-line change.
  - `nano-server-reactos-tools/shim/`: `Cargo.toml`, `src/lib.rs` (the `__chkstk` asm) and `build.rs` (or a pwsh script) that writes `rosk32sh.def`
  - `nano-server-reactos-tools/scripts/Get-PeImports.ps1`, `New-ShimDef.ps1`, `Set-PeImportName.ps1`
  - `nano-server-reactos-tools/tests/run-tests.cmd` and `tests/fixtures/`
  - `nano-server-reactos-tools/licenses/COPYING` (GPL-2.0 text from the ReactOS tree) and `licenses/SOURCE.md`
- Install directory in the image: `C:\Program Files\reactos-tools\` (the patched tools plus `rosk32sh.dll`, `COPYING`, `SOURCE.md`)
- `PATH`: append `C:\Program Files\reactos-tools` after the existing entries, so Microsoft tools always win.

## Dockerfile

Follow the repo convention. The base image is an argument, and every version is pinned in `ENV` or `ARG`.

```dockerfile
ARG WINDOWS_VERSION=2022
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64

# ---------- builder: fetch, extract, build shim, patch ----------
FROM ${BASE_IMAGE} AS builder
USER ContainerAdministrator
ENV \
    ROS_BUILD=0.4.17-dev-1302-ge25c373 \
    ROS_COMMIT=e25c37366b65d94985522a931f76351d6b244234 \
    ROS_SHA256=AFA7B62A626C440874FF04D51EBA5C5B2AB357E79A7BD467BE47D6F8F4D0D59A \
    SEVENZIP_VERSION=2605 \
    PWSH_VERSION=7.6.9 \
    RUSTUP_VERSION=1.29.3 \
    RUST_VERSION=1.99.1 \
    RUST_HOST=x86_64-pc-windows-gnu
# 1. pwsh: curl the zip, tar -xf into C:\pwsh
# 2. 7-Zip: curl 7zr.exe and 7z%SEVENZIP_VERSION%-x64.exe; 7zr x -oC:\7z
# 3. ReactOS: curl the .7z, check SHA-256 with pwsh Get-FileHash (fail the build if it differs),
#    C:\7z\7z.exe x the .7z, then 7z.exe x the .iso reactos\system32\* -oC:\ros
# 4. Copy each file named in tools.txt from C:\ros\reactos\system32 to C:\out
# 5. pwsh scripts\New-ShimDef.ps1 -Tools C:\out -Out C:\shim\rosk32sh.def
# 6. Rust (same install steps as nano-server-rust) and cargo build --release for the shim,
#    with RUSTFLAGS=-C link-arg=C:/shim/rosk32sh.def; copy rosk32sh.dll to C:\out
# 7. pwsh scripts\Set-PeImportName.ps1 on every .exe and .com in C:\out
# 8. pwsh scripts\Get-PeImports.ps1 -Check: fail the build if any tool still imports kernel32.dll
#    or imports a name the shim does not export

# ---------- final ----------
FROM ${BASE_IMAGE}
ARG ROS_COMMIT=e25c37366b65d94985522a931f76351d6b244234
LABEL org.opencontainers.image.source="https://github.com/zippy1981/windows-nano-demos" \
      org.reactos.commit="${ROS_COMMIT}" \
      org.opencontainers.image.licenses="GPL-2.0-or-later AND LGPL-2.1-or-later"
COPY --from=builder ["C:/out/", "C:/Program Files/reactos-tools/"]
COPY licenses/ ["C:/Program Files/reactos-tools/"]
COPY tests/ C:/tests/
# The user PATH is empty here and Windows appends it after the system PATH,
# so Microsoft's tools in System32 always win.
RUN reg query HKCU\Environment 2> NUL || reg add HKCU\Environment /v PATH
RUN setx PATH "C:\Program Files\reactos-tools"
ENTRYPOINT ["cmd", "/S", "/C"]
```

Notes for the implementer:

- `setx` writes the user `PATH` of the default user (`ContainerUser`). `nano-server-php` uses the same approach, including the `reg add` workaround that ltsc2019 needs. Check that `where find` resolves in a new `docker run`, and also with `docker run --user ContainerAdministrator`. If the second fails, document it in the README rather than editing the machine `PATH`.
- The builder stage downloads about 600 MB (Rust, ISO). Order the layers so that the ReactOS download and the Rust install are cached separately from `tools.txt` and the scripts.
- The final image must contain only the patched tools, the shim, licenses and tests. Target: base image plus less than 10 MB.

## Licensing

- ReactOS is mostly **GPL-2.0-or-later**. Many user-mode pieces came from Wine and are **LGPL-2.1-or-later**, and a few files are BSD or MIT. See `COPYING` and `COPYING.LIB` in <https://github.com/reactos/reactos> and <https://github.com/reactos/reactos/blob/master/CREDITS>.
- Pushing the image to Docker Hub is distribution of object code. GPL-2.0 section 3 then requires the complete corresponding source. Plan:
  - Section 3(a) is the most robust option: publish the source archive at the pinned commit, `https://github.com/reactos/reactos/archive/e25c37366b65d94985522a931f76351d6b244234.zip`, as a release asset in this repo next to the image tag. A link to someone else's server is weaker than hosting it ourselves.
  - The binary patch is a modification. The scripts that make it (`Set-PeImportName.ps1`, the shim source and the `.def` generator) are in this repo and are part of the corresponding source. License them GPL-2.0-or-later (or MIT, which is compatible) and say so in their headers.
  - `C:\Program Files\reactos-tools\SOURCE.md` gives the ReactOS commit, the boot CD URL and SHA-256, the release asset URL, and the URL of this repo at the image's commit.
  - `C:\Program Files\reactos-tools\COPYING` holds the GPL-2.0 text, and `COPYING.LIB` holds the LGPL-2.1 text.
- The Microsoft nanoserver base layers come under Microsoft's container image license. Putting GPL tools in the same image is mere aggregation and does not affect either license. Add a short "Licensing" section to the folder README that says this.
- This is an engineering reading, not legal advice. Note that in the PR.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Nightlies are debug builds of alpha software | Asserts, `DbgPrint` noise, bugs | Pin one build; every tool is covered by a test; upgrade only on purpose |
| Nightlies are purged from `iso.reactos.org` | Build breaks | Mirror the pinned `.7z` as a GitHub release asset |
| `__chkstk` asm is wrong | Stack corruption on large frames | Add a test that runs a tool with a frame over 4 KiB on a long input (`find` and `sort` on a 1 MB file, `tree /f` on a deep tree) |
| Forwarders differ between ltsc2019, 2022 and 2025 | A tool loads on one version and not another | The CI matrix runs every test on all three; the import check runs against each base image's forwarders (phase 2) |
| ReactOS `msvcrt` exports that Microsoft's `msvcrt` lacks | Load failure | The build-time import check fails the build |
| Output format differs from Microsoft's tool | Scripts that parse output break | README says these are ReactOS versions; tests pin ReactOS output |
| Shadowing a Microsoft tool | Changed behaviour of existing scripts | Install outside `System32`, append to `PATH`, and the build fails if a tool in `tools.txt` also exists in the base image's `System32` |
| Unsigned binaries | AppLocker or Defender policies may block them | Document it; nothing to do in a dev image |
| GPL compliance | Licence violation on push | Source release asset, `SOURCE.md` and `COPYING` are acceptance criteria for publishing |

## Test plan

Tests are baked into the image at `C:\tests\run-tests.cmd`, because the runner is a container and cannot bind-mount the workspace. The script uses only `cmd` built-ins and nanoserver's `findstr`, writes [TAP](https://testanything.org/) to stdout, and exits with the number of failures.

Each test runs a tool, captures stdout and stderr to a file, checks the exit code, and runs `findstr /r /c:"<regex>"` on the file:

| # | Command | Expected exit | Expected output (regex) |
| --- | --- | --- | --- |
| 1 | `find "one" C:\tests\fixtures\a.txt` | 0 | `^one` |
| 2 | `type C:\tests\fixtures\a.txt \| find /c "one"` | 0 | `^1$` |
| 3 | `type C:\tests\fixtures\a.txt \| more` | 0 | `^one` |
| 4 | `fc C:\tests\fixtures\a.txt C:\tests\fixtures\b.txt` | 1 | `^\*\*\*\*\*` |
| 5 | `fc C:\tests\fixtures\a.txt C:\tests\fixtures\a.txt` | 0 | `no differences` (case-insensitive) |
| 6 | `where cmd` | 0 | `\\cmd\.exe$` |
| 7 | `whoami` | 0 | `\\containeruser$` (case-insensitive) |
| 8 | `tree /f C:\tests\fixtures` | 0 | `a\.txt` |
| 9 | `echo n\| comp C:\tests\fixtures\a.txt C:\tests\fixtures\a.txt` | 0 | `compare OK` |
| 10 | `tasklist` | 0 | `cmd\.exe` |
| 11 | `taskkill /?` | 0 | `taskkill` |
| 12 | `chcp` | 0 | `code page` |
| 13 | `mode con` | 0 | `CON` |
| 14 | `help dir` | 0 | `DIR` |
| 15 | `replace /?` | 0 | `REPLACE` |
| 16 | `fsutil fsinfo drives` | 0 | `C:\\` |
| 17 | `nslookup localhost` | 0 | `127\.0\.0\.1` |
| 18 | `cacls C:\tests\fixtures\a.txt` | 0 | `a\.txt` |
| 19 | `find /c "x" C:\tests\fixtures\big.txt` (1 MB file made by the test with a `for /l` loop) | 0 | `^[0-9]` (stack-probe check) |
| 20 | For each tool in `tools.txt`: `<tool> /?` | not -1073741511 and not -1073741515 | none (load check) |

Test 20 is the generic load check: it fails on `STATUS_ENTRYPOINT_NOT_FOUND` (-1073741511) and `STATUS_DLL_NOT_FOUND` (-1073741515) for any tool.

## CI

Workflow `.github/workflows/reactos-tools-container.yml`, modelled on the Rust container workflow:

```yaml
name: ReactOS tools container
on:
  push:
    branches: [main]
    paths: ['nano-server-reactos-tools/**', '.github/workflows/reactos-tools-container.yml']
  pull_request:
    branches: [main]
    paths: ['nano-server-reactos-tools/**', '.github/workflows/reactos-tools-container.yml']
  workflow_dispatch:
jobs:
  build-and-test:
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    runs-on: [self-hosted, windows, docker]
    strategy:
      fail-fast: false
      matrix:
        windows-version: ['2019', '2022', '2025']
    defaults:
      run:
        shell: pwsh
    env:
      IMAGE: windows-nano-reactos-tools:${{ matrix.windows-version }}-${{ github.sha }}
    steps:
      - uses: actions/checkout@v4
      - name: Build
        working-directory: nano-server-reactos-tools
        run: |
          docker build --build-arg WINDOWS_VERSION=${{ matrix.windows-version }} -t $env:IMAGE .
          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
      - name: Test
        run: |
          docker run --name rt-${{ github.run_id }}-${{ matrix.windows-version }} $env:IMAGE "C:\tests\run-tests.cmd > C:\tests\results.tap & type C:\tests\results.tap"
          $rc = $LASTEXITCODE
          docker cp "rt-${{ github.run_id }}-${{ matrix.windows-version }}:C:\tests\results.tap" "results-${{ matrix.windows-version }}.tap"
          exit $rc
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: reactos-tools-tap-${{ matrix.windows-version }}
          path: results-${{ matrix.windows-version }}.tap
      - name: Clean up
        if: always()
        run: |
          docker rm -f rt-${{ github.run_id }}-${{ matrix.windows-version }} 2>$null
          docker rmi -f $env:IMAGE
          exit 0
```

`docker cp` from a stopped Windows container works over the named pipe, so no bind mount is needed. If `docker cp` fails on a version, fall back to reading the TAP from the `docker run` stdout.

## Phased task checklist

### Phase 1: image on ltsc2022

- [ ] Create `nano-server-reactos-tools/` with `Dockerfile`, `build.cmd`, `README.md`, `tools.txt`, `scripts/`, `shim/`, `tests/` and `licenses/`.
- [ ] Mirror the pinned boot CD `.7z` as a GitHub release asset and record its URL and SHA-256 in the Dockerfile.
- [ ] Port the prototype scripts in the appendix into `scripts/`, with comments and parameter validation.
- [ ] Builder stage: pwsh, 7-Zip, download with hash check, extract, build the shim, patch, import check.
- [ ] Final stage: tools, shim, licenses, tests, `PATH`.
- [ ] `tests/run-tests.cmd` with tests 1 to 20, TAP output.
- [ ] Acceptance: `build.cmd` succeeds on the host for `WINDOWS_VERSION=2022`; `docker run --rm windows-nano-reactos-tools:2022 C:\tests\run-tests.cmd` exits 0; the final image is less than 10 MB larger than the base; the build fails if the SHA-256 is wrong or if a tool still imports `kernel32.dll`.

### Phase 2: CI matrix over 2019, 2022 and 2025

- [ ] Add `.github/workflows/reactos-tools-container.yml` as above.
- [ ] Make the import check resolve against the forwarders of the base image being built (copy `C:\Windows\System32\forwarders\*.dll`, `KernelBase.dll`, `kernel32legacy.dll`, `msvcrt.dll` and `ucrtbase.dll` from the base into the builder and check every import name against their exports).
- [ ] Drop any tool from `tools.txt` for a version where it cannot load, using a per-version list (`tools-2019.txt` overrides) only if needed.
- [ ] Acceptance: all three matrix legs are green on the self-hosted runner; TAP artifacts are uploaded for each leg.

### Phase 3: wider coverage and clean-up

- [ ] Retest `timeout` with `docker run -t`, and `subst`; move them to tier 1 or record why not.
- [ ] Investigate `cscript.exe` (access violation) and `certutil -hashfile` (error 234). Record the result in the README.
- [ ] Try forwarding `__chkstk` to `ntdll.__chkstk` and drop the asm if all tests pass on all three versions.
- [ ] Optional: try ReactOS `netapi32.dll` app-local for `net.exe` (expected to fail; record the result).
- [ ] Acceptance: README has a table of every tool tried, its status on each Windows version, and the reason for each tool that is left out.

### Phase 4: publish

- [ ] Source archive and `SOURCE.md` attached to a GitHub release whose name matches the image tag.
- [ ] Push `zippy1981/windows-nano-reactos-tools:<version>` only when the user asks (use the `windows-image-publisher` agent).
- [ ] Acceptance: the Docker Hub description links to the source release and states the licenses.

## Prototype results

Run on ltsc2022 with process isolation, ReactOS build `0.4.17-dev-1302-ge25c373` x64:

- **Without the shim:** every tool that imports `__chkstk` exited with -1073741511 (`STATUS_ENTRYPOINT_NOT_FOUND`) and printed nothing. `attrib`, `cacls`, `doskey`, `fsutil`, `extrac32`, `nslookup`, `whois`, `ftp` and `rundll32` ran, because they do not import `__chkstk`.
- **With the shim:** `find`, `more`, `fc`, `where`, `whoami`, `tree`, `comp`, `tasklist`, `taskkill`, `chcp`, `mode`, `help`, `hostname`, `sort`, `xcopy`, `findstr`, `cmd`, `replace`, `label`, `shutdown`, `eventcreate` and `runas` ran and gave correct output.
- **Still failing with the shim:** `reg` and `net` (missing DLLs, -1073741515), `msiexec` (missing `msi.dll`), `expand` (missing `setupapi` exports), `cscript` (access violation, -1073741819), `clip` (no clipboard), `certutil -hashfile` (error 234).

## Appendix: prototype code

Generating the `.def` file (pwsh). `Get-PeImports.ps1` prints `exe!dll!function` for each import. Port it from the prototype, which parsed the PE32+ import directory by hand.

```powershell
$fns = & .\Get-PeImports.ps1 -Path (Get-ChildItem C:\out\*.exe, C:\out\*.com).FullName |
    Where-Object { ($_ -split '!')[1] -ieq 'kernel32.dll' } |
    ForEach-Object { ($_ -split '!')[2] } | Sort-Object -Unique
$def = @('LIBRARY rosk32sh.dll', 'EXPORTS') + ($fns | ForEach-Object {
    if ($_ -eq '__chkstk') { '    __chkstk = ros_chkstk' } else { "    $_ = kernel32.$_" }
})
Set-Content C:\shim\rosk32sh.def $def -Encoding ascii
```

The shim's `src/lib.rs` (crate type `cdylib`, `panic = "abort"`, built with `RUSTFLAGS=-C link-arg=C:/shim/rosk32sh.def`):

```rust
#![no_std]
#[panic_handler]
fn p(_: &core::panic::PanicInfo) -> ! { loop {} }
// MSVC-compatible x64 __chkstk: RAX = bytes to probe; touches each page; preserves all regs but flags.
core::arch::global_asm!(
    ".globl ros_chkstk",
    "ros_chkstk:",
    "push rcx",
    "push rax",
    "cmp rax, 0x1000",
    "lea rcx, [rsp+24]",
    "jb 2f",
    "1:",
    "sub rcx, 0x1000",
    "or qword ptr [rcx], 0",
    "sub rax, 0x1000",
    "cmp rax, 0x1000",
    "ja 1b",
    "2:",
    "sub rcx, rax",
    "or qword ptr [rcx], 0",
    "pop rax",
    "pop rcx",
    "ret",
);
```

The import-name rewrite (core of `Set-PeImportName.ps1`): walk the import directory (data directory 1). For each descriptor whose name string equals `kernel32.dll` (without regard to case, followed by a NUL), overwrite those 12 bytes with `rosk32sh.dll`. Zero the optional header checksum (offset 64 in the optional header), and write the file back. Refuse to run if the two names differ in length.

## Sources

- ReactOS downloads: <https://reactos.org/download/>
- ReactOS nightly builds: <https://reactos.org/getbuilds/> and <https://iso.reactos.org/bootcd/>
- ReactOS releases (x86 only): <https://github.com/reactos/reactos/releases>
- ReactOS AMD64 port status: <https://www.reactos.org/wiki/AMD64>
- ReactOS license: <https://github.com/reactos/reactos/blob/master/COPYING> and <https://github.com/reactos/reactos/blob/master/CREDITS>
- GPL-2.0 text: <https://www.gnu.org/licenses/old-licenses/gpl-2.0.html>
- 7-Zip: <https://www.7-zip.org/download.html>
- PowerShell releases: <https://github.com/PowerShell/PowerShell/releases>
- llvm-mingw: <https://github.com/mstorsjo/llvm-mingw/releases>
- x64 prolog and stack probe (`__chkstk`): <https://learn.microsoft.com/en-us/cpp/build/prolog-and-epilog>
- PE import directory format: <https://learn.microsoft.com/en-us/windows/win32/debug/pe-format#the-idata-section>
