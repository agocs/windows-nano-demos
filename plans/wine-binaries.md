# Plan: nanoserver image with Wine's command-line programs

## Goal

Build a nanoserver image variant, `nano-server-wine-tools/`, that adds console tools nanoserver lacks (`find`, `fc`, `where`, `whoami`, `tasklist`, `taskkill`, `start` and others). The tools are the PE builds of Wine's built-in programs. Wine has built its modules as real PE files with a MinGW cross compiler since Wine 5.x and 6.x. Since Wine 8 and later (`--enable-archs`), every module is a PE file, and the code that talks to the Unix side lives in separate `.so` "unixlibs".

This plan is based on a prototype run on the host (Windows 11 build 26300, nanoserver `ltsc2022` 10.0.20348.5773, process isolation) with the **unmodified** x86_64 PE files from WineHQ's Wine 11.0 package. See [Prototype results](#prototype-results).

See `plans/reactos-binaries.md` (branch `plan/reactos-binaries`) for the audit of what nanoserver lacks compared with servercore. That plan is the ReactOS alternative. The two images are independent and can both exist.

## Summary of decisions

- **Source:** the WineHQ **stable** Ubuntu 24.04 (noble) package `wine-stable-amd64_11.0.0.0~noble-1_amd64.deb`. The PE files are plain files in `opt/wine-stable/lib/wine/x86_64-windows/`. No compiler is needed. A build from source is phase 3, and is only for reproducibility.
- **Where the extraction runs:** in CI, an `ubuntu-latest` job extracts the `.deb` with `dpkg-deb`, picks the files, and uploads them as an artifact. The Windows job downloads the artifact into the build context. For local builds, `fetch-wine.ps1` does the same on the Windows 11 host with the built-in `tar.exe` (bsdtar 3.8, which reads `ar`, zstd and xz).
- **No patching needed:** unlike ReactOS, Wine's x64 PE programs resolve against nanoserver's own DLLs. The prototype loaded them unmodified. Wine's PE programs link `ucrtbase.dll` (present in nanoserver), and Wine's debug channel calls are linked statically from `winecrt0`. That code looks up `__wine_dbg_*` in `ntdll` at run time and falls back when they are missing, so nothing imports Wine-only `ntdll` exports.
- **Safe-module rule:** only copy a Wine module if (1) it is not a core system DLL, (2) it has no unixlib (`lib/wine/x86_64-unix/<name>.so`), and (3) every import resolves against the base image (checked at build time). In phase 1 only `.exe` programs are copied, with no Wine DLLs at all.
- **Install location:** `C:\Program Files\wine-tools`, appended after the system `PATH`. Nothing goes into `System32`.
- **Licensing:** Wine is LGPL-2.1-or-later. The image ships `COPYING.LIB`, `AUTHORS` and `SOURCE.md`, and the matching source tarball is attached to a GitHub release.
- **Noise:** set `WINEDEBUG=-all` in the image. Without it, stub programs print `fixme:` lines to stderr. The prototype showed that `winecrt0`'s fallback honours `WINEDEBUG` on Windows.

## How to obtain the PE files

### Pinned package

- Index: `https://dl.winehq.org/wine-builds/ubuntu/dists/noble/main/binary-amd64/Packages`
- Package: `wine-stable-amd64`, version `11.0.0.0~noble-1`
- URL: `https://dl.winehq.org/wine-builds/ubuntu/pool/main/w/wine/wine-stable-amd64_11.0.0.0~noble-1_amd64.deb`
- Size: 122,823,532 bytes
- SHA-256: `6cb835e2171b5572b17f1c06729735c2c7e40178239d7fa6c29ef14bd9b40d16` (matches the `Packages` index and the prototype download)
- Contents: `data.tar.zst`. The PE modules (1,018 files) are in `./opt/wine-stable/lib/wine/x86_64-windows/`, and the unixlibs are in `./opt/wine-stable/lib/wine/x86_64-unix/`.
- Matching source: `https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz` (33,172,240 bytes), tag `wine-11.0` (`ce295733f9a67970b7f60d7af201f2ac16441a50` in <https://gitlab.winehq.org/wine/wine>).

`wine-stable` is preferred over `wine-devel` (11.21 at the time of writing): it changes less often, and each pinned version has a single source tarball.

### Option A (phase 1): extract the WineHQ package

CI job `extract-wine` on `ubuntu-latest`:

```sh
set -euo pipefail
WINE_DEB_URL="https://dl.winehq.org/wine-builds/ubuntu/pool/main/w/wine/wine-stable-amd64_11.0.0.0~noble-1_amd64.deb"
WINE_DEB_SHA256="6cb835e2171b5572b17f1c06729735c2c7e40178239d7fa6c29ef14bd9b40d16"
curl -fsSL -o wine.deb "$WINE_DEB_URL"
echo "$WINE_DEB_SHA256  wine.deb" | sha256sum -c -
dpkg-deb -x wine.deb root
PE=root/opt/wine-stable/lib/wine/x86_64-windows
UNIX=root/opt/wine-stable/lib/wine/x86_64-unix
mkdir -p out
while read -r f; do
  [ -z "$f" ] && continue
  case "$f" in \#*) continue;; esac
  base="${f%.*}"
  if [ -e "$UNIX/$base.so" ]; then echo "refusing $f: has a unixlib" >&2; exit 1; fi
  cp "$PE/$f" out/
done < nano-server-wine-tools/tools.txt
ls -l out
```

Upload `out/` as the artifact `wine-pe-11.0`. The Windows job downloads it into `nano-server-wine-tools/wine-pe/`. The artifact is about 2 MB.

### Option B (local builds): the same thing on the Windows host

`nano-server-wine-tools/fetch-wine.ps1` (pwsh 7): download with `curl.exe -fsSL`, check `Get-FileHash`, then `tar -xf wine.deb data.tar.zst` and `tar -xf data.tar.zst ./opt/wine-stable/lib/wine/x86_64-windows/<file>` for each entry in `tools.txt`. Copy the files into `wine-pe\`. This was checked on the host: Windows 11's `tar.exe` (bsdtar 3.8.9 with libzstd) extracts this `.deb`. The full extract hits one error on a Linux-only path under `usr/share/doc`, so extract only the listed member paths. `build.cmd` calls `fetch-wine.ps1` if `wine-pe\` is empty.

### Option C (phase 3): build from source

For reproducibility and so the source we ship matches the binaries exactly, build in an `ubuntu-24.04` job:

```sh
sudo apt-get install -y gcc-mingw-w64-x86-64 gcc make flex bison
curl -fsSLO https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz
tar -xf wine-11.0.tar.xz && cd wine-11.0
./configure --enable-archs=x86_64 --without-x --without-freetype --without-wayland \
  --without-alsa --without-pulse --without-gstreamer --without-vulkan --without-opengl
make -j"$(nproc)" programs/find/x86_64-windows/find.exe programs/fc/x86_64-windows/fc.exe  # one target per tool
```

Each program's PE output is in `programs/<name>/x86_64-windows/<name>.exe`. Compare the import tables of the built files with the WineHQ ones before switching the image to option C.

## Wine-specific dependencies: what is safe on real Windows

Wine's PE modules fall into three groups.

1. **Core modules that wrap the Unix side** must **never** be copied: `ntdll`, `win32u`, `kernel32`, `kernelbase`, `user32`, `gdi32`, `advapi32`, `ws2_32`, `msvcrt`, `ucrtbase`, `combase`, `ole32`, `rpcrt4`, `sechost`. Wine's `ntdll.dll` makes `__wine_unix_call` and syscalls into `ntdll.so`. On real NT these modules would either refuse to load (KnownDLLs win anyway) or break every process that loads them.
2. **Modules with a unixlib** (`lib/wine/x86_64-unix/<name>.so` exists): `bcrypt`, `crypt32`, `dnsapi`, `netapi32`, `odbc32`, `opengl32`, `secur32`, `winspool`, `ws2_32`, `mountmgr`, `nsiproxy`, `winex11`, `winewayland`, `winevulkan`, `winegstreamer` and others in the 11.0 package. Their PE half calls `__wine_init_unix_call`. On Windows that fails, and the module either falls back to a degraded mode or fails. Do not copy them. `netapi32` is the one that `net.exe` needs, so Wine's `net.exe` cannot be fixed this way.
3. **Pure PE modules** (no unixlib, only Win32 imports): all the console programs, and DLLs such as `cabinet`, `jscript`, `vbscript`, `scrrun` and `msi`. These are the safe ones. A pure PE DLL is still only usable if its imports resolve in nanoserver. `msi.dll` imports `urlmon`, `wininet` and `comctl32`, and the first two do not exist in nanoserver, so it is not usable.

Debug output: Wine's `WINE_FIXME`, `TRACE` and `ERR` macros call `__wine_dbg_*`. In PE builds these come from the static `winecrt0` library, which tries `GetProcAddress(ntdll, "__wine_dbg_...")` and otherwise falls back to writing to stderr according to `WINEDEBUG`. The prototype showed `fixme:` lines from `tasklist`, `robocopy` and `icacls`, and showed that `WINEDEBUG=-all` silences them.

Build-time check: `scripts/Test-PeImports.ps1` (the same script as in the ReactOS plan; share it if that plan has landed) copies the base image's `System32\forwarders\*.dll`, `KernelBase.dll`, `kernel32legacy.dll`, `ucrtbase.dll`, `ntdll.dll` and any other DLL that the tools import into the builder stage. It then fails the build if any import name in any copied tool is missing from those exports.

## Which programs are worth shipping

### Tier 1: worked unmodified in the prototype (ltsc2022)

| Program | Prototype result | Nanoserver has its own? |
| --- | --- | --- |
| `find.exe` | `find "one" a.txt` prints `---------- A.TXT` and `one`. `type a.txt \| find /c "one"` printed nothing: retest | No |
| `fc.exe` | `Comparing files a.txt and b.txt`, exit code 1 when files differ | No |
| `where.exe` | `C:\Windows\system32\cmd.exe` | No |
| `whoami.exe` | `User Manager\ContainerUser` | No |
| `tasklist.exe` | Correct table; `fixme` noise without `WINEDEBUG=-all` | No |
| `taskkill.exe` | `/?` prints usage | No |
| `start.exe` | `/?` prints full help. Useful as a real `start.exe` for tools that spawn it | `start` is a `cmd` built-in only |
| `hostname.exe` | Prints the container name | Yes (skip) |
| `attrib.exe` | `A C:\work\a.txt` | Yes (skip) |
| `xcopy.exe`, `sort.exe`, `findstr.exe`, `reg.exe`, `ipconfig.exe`, `ping.exe`, `sc.exe` | Work | Yes (skip) |
| `fsutil.exe` | Prints its command list; only `hardlink` is implemented | No (ship, low value) |
| `cabarc.exe` | Exit code 0 creating a cabinet; verify that the `.cab` lists | No |

Ship: `find`, `fc`, `where`, `whoami`, `tasklist`, `taskkill`, `start`, `cabarc`, `fsutil`. Do not ship tools that nanoserver already has, because a different implementation earlier or later in `PATH` causes confusion.

### Tier 2: try in phase 2

- `timeout.exe`: prints `ERROR: not possible to redirect input` (exit code 101) when stdin is not a console. Retest with `docker run -t`.
- `cscript.exe` and `wscript.exe`: they start, but need Wine's `jscript.dll` and `vbscript.dll` registered as COM servers. Phase 2 experiment: copy `jscript.dll`, `vbscript.dll` and `scrrun.dll` (pure PE) app-local and register them with nanoserver's `regsvr32`.
- `regedit.exe` (`/E` export only, console use), `notepad.exe`: nanoserver has no GUI, so skip.

### Do not ship (stubs or broken on nanoserver)

| Program | Why |
| --- | --- |
| `cmd.exe` | Imports `kernel32!VerifyConsoleIoHandle`, which nanoserver's `kernel32` lacks (exit code -1073741511) |
| `expand.exe` | Imports `setupapi!SetupIterateCabinetA`, missing in nanoserver (exit code -1073741511) |
| `net.exe` | Needs `netapi32.dll` (exit code -1073741515) |
| `klist.exe` | Access violation (exit code -1073741819) |
| `wmic.exe` | Exit code -1; needs Wine's WMI provider `wbemprox` |
| `robocopy.exe` | Wine stub: `fixme:robocopy:wmain robocopy stub`, exit code 16 |
| `certutil.exe`, `icacls.exe`, `cacls.exe`, `makecab.exe`, `setx.exe`, `shutdown.exe`, `wevtutil.exe`, `schtasks.exe`, `subst.exe` | Stubs that print `fixme ... stub` and do nothing |
| `systeminfo.exe` | Prints nothing, exit code 0 |
| `netstat.exe` | Does not know `-n` |
| `winepath.exe`, `wineboot.exe`, `winecfg.exe` and other `wine*` programs | Need the Wine `ntdll` exports (`wine_get_dos_file_name` and others) |
| `more` | Wine has no `more.exe` (use the ReactOS plan's `more.com`) |

## Image layout

- Folder: `nano-server-wine-tools/`
- Image: `windows-nano-wine-tools:<WINDOWS_VERSION>` and `zippy1981/windows-nano-wine-tools:<WINDOWS_VERSION>`
- Files:
  - `Dockerfile`, `build.cmd`, `README.md`, `.gitignore` (ignores `wine-pe/`)
  - `tools.txt`: one PE file name per line (tier 1), used by both the CI job and `fetch-wine.ps1`
  - `fetch-wine.ps1`: option B
  - `scripts/Test-PeImports.ps1`
  - `tests/run-tests.cmd` and `tests/fixtures/`
  - `licenses/COPYING.LIB`, `licenses/AUTHORS` (both from the `wine-11.0` tarball) and `licenses/SOURCE.md`
- Install directory: `C:\Program Files\wine-tools\`, holding the tools and the license files
- Environment: `WINEDEBUG=-all`, and `PATH` with `C:\Program Files\wine-tools` appended

## Dockerfile

```dockerfile
ARG WINDOWS_VERSION=2022
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64

# ---------- check: imports must resolve against this base ----------
FROM ${BASE_IMAGE} AS check
USER ContainerAdministrator
ENV PWSH_VERSION=7.6.9
RUN mkdir C:\pwsh && \
    curl -fsSL -o pwsh.zip https://github.com/PowerShell/PowerShell/releases/download/v%PWSH_VERSION%/PowerShell-%PWSH_VERSION%-win-x64.zip && \
    tar -xf pwsh.zip -C C:\pwsh && del pwsh.zip
COPY wine-pe/ C:/wine-pe/
COPY scripts/ C:/scripts/
RUN C:\pwsh\pwsh.exe -NoProfile -File C:\scripts\Test-PeImports.ps1 -Path C:\wine-pe -System32 C:\Windows\System32

# ---------- final ----------
FROM ${BASE_IMAGE}
ARG WINE_VERSION=11.0
LABEL org.opencontainers.image.source="https://github.com/zippy1981/windows-nano-demos" \
      org.winehq.version="${WINE_VERSION}" \
      org.opencontainers.image.licenses="LGPL-2.1-or-later"
ENV WINEDEBUG=-all
COPY --from=check ["C:/wine-pe/", "C:/Program Files/wine-tools/"]
COPY licenses/ ["C:/Program Files/wine-tools/"]
COPY tests/ C:/tests/
RUN reg query HKCU\Environment 2> NUL || reg add HKCU\Environment /v PATH
RUN setx PATH "C:\Program Files\wine-tools"
ENTRYPOINT ["cmd", "/S", "/C"]
```

`COPY --from=check` makes the final stage depend on the check stage, so BuildKit or the classic builder cannot skip it. The check therefore always runs. The final image adds about 2 MB to the base.

## Licensing

- Wine is **LGPL-2.1-or-later** (`COPYING.LIB` in the source tree, <https://wiki.winehq.org/Licensing>).
- Pushing the image to Docker Hub distributes the object code. LGPL-2.1 section 6 (and section 4 for the library parts) requires the complete corresponding source, or a written offer:
  - Attach `wine-11.0.tar.xz` from `https://dl.winehq.org/wine/source/11.0/` to a GitHub release in this repo whose name matches the image tag. If option C is used, also attach the exact `configure` line and build log.
  - `C:\Program Files\wine-tools\SOURCE.md` lists the Wine version, the `.deb` URL and SHA-256, the source tarball URL, and the release asset URL.
  - We do not modify Wine binaries, so there are no patches to publish. The extraction scripts are in this repo anyway.
- The programs are separate executables next to Microsoft's base layers. That is aggregation, and LGPL relinking terms do not reach Microsoft's DLLs.
- This is an engineering reading, not legal advice.

## Test plan

`C:\tests\run-tests.cmd` is baked into the image, writes TAP, and exits with the number of failures. It uses only `cmd` built-ins and nanoserver's own `findstr` for the checks, so a broken Wine tool cannot hide its own failure.

| # | Command | Expected exit | Expected output (regex) |
| --- | --- | --- | --- |
| 1 | `find "one" C:\tests\fixtures\a.txt` | 0 | `^one` |
| 2 | `find /c "one" C:\tests\fixtures\a.txt` | 0 | `: 1$` |
| 3 | `type C:\tests\fixtures\a.txt \| find "one"` | 0 | `^one` |
| 4 | `fc C:\tests\fixtures\a.txt C:\tests\fixtures\b.txt` | 1 | `Comparing files` |
| 5 | `fc C:\tests\fixtures\a.txt C:\tests\fixtures\a.txt` | 0 | `no differences` (case-insensitive) |
| 6 | `where cmd` | 0 | `\\cmd\.exe$` |
| 7 | `where /q nosuchtool` | 1 | none |
| 8 | `whoami` | 0 | `\\ContainerUser$` (case-insensitive) |
| 9 | `tasklist` | 0 | `tasklist\.exe` |
| 10 | `tasklist /fi "imagename eq cmd.exe"` | 0 | `cmd\.exe` |
| 11 | `taskkill /?` | 0 | `taskkill` |
| 12 | `start /b /wait cmd /c exit 3` | 3 | none |
| 13 | `cabarc n C:\work\t.cab C:\tests\fixtures\a.txt` then `cabarc l C:\work\t.cab` | 0 | `a\.txt` |
| 14 | `fsutil hardlink create C:\work\h.txt C:\tests\fixtures\a.txt` | 0 | none, then `type C:\work\h.txt` contains `one` |
| 15 | For each tool in `tools.txt`: `<tool> /?` | not -1073741511, -1073741515 or -1073741819 | none (load check) |
| 16 | With `WINEDEBUG` unset: `tasklist 2>&1` contains `fixme`; with `-all` it does not | 0 | regex check both ways |

Tests 2, 3 and 12 have not been run yet. If one fails on Wine 11.0, record it and drop the feature from the README rather than the tool, unless the tool becomes useless.

## CI

Workflow `.github/workflows/wine-tools-container.yml`:

```yaml
name: Wine tools container
on:
  push:
    branches: [main]
    paths: ['nano-server-wine-tools/**', '.github/workflows/wine-tools-container.yml']
  pull_request:
    branches: [main]
    paths: ['nano-server-wine-tools/**', '.github/workflows/wine-tools-container.yml']
  workflow_dispatch:
jobs:
  extract-wine:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Extract Wine PE programs
        run: bash nano-server-wine-tools/extract-wine.sh   # the Option A script
      - uses: actions/upload-artifact@v4
        with:
          name: wine-pe
          path: out/
  build-and-test:
    needs: extract-wine
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
      IMAGE: windows-nano-wine-tools:${{ matrix.windows-version }}-${{ github.sha }}
      CTR: wt-${{ github.run_id }}-${{ matrix.windows-version }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: wine-pe
          path: nano-server-wine-tools/wine-pe
      - name: Build
        working-directory: nano-server-wine-tools
        run: |
          docker build --build-arg WINDOWS_VERSION=${{ matrix.windows-version }} -t $env:IMAGE .
          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
      - name: Test
        run: |
          docker run --name $env:CTR $env:IMAGE "C:\tests\run-tests.cmd > C:\tests\results.tap & type C:\tests\results.tap"
          $rc = $LASTEXITCODE
          docker cp "$($env:CTR):C:\tests\results.tap" "results-${{ matrix.windows-version }}.tap"
          exit $rc
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: wine-tools-tap-${{ matrix.windows-version }}
          path: results-${{ matrix.windows-version }}.tap
      - name: Clean up
        if: always()
        run: |
          docker rm -f $env:CTR 2>$null
          docker rmi -f $env:IMAGE
          exit 0
```

The self-hosted runner is a nanoserver container. `actions/download-artifact` runs on the runner's bundled Node, writes into the checkout, and `docker build` streams that context to the host daemon over the named pipe. No bind mount is involved.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Wine programs are partial reimplementations | Missing switches, different output | Ship only tier 1; README lists the switches the tests cover |
| A future Wine version imports an API nanoserver lacks | Load failure | `Test-PeImports.ps1` fails the build per base image |
| `fixme:` noise breaks scripts that parse stderr | Spurious output | `ENV WINEDEBUG=-all` and test 16 |
| ltsc2019 forwarders export less | Tools load on 2022 but not on 2019 | The matrix and the import check run per version; per-version `tools-2019.txt` only if needed |
| WineHQ removes the pinned `.deb` | Build breaks | Mirror the `.deb` (or just the `wine-pe` files and the source tarball) as a release asset |
| Somebody copies a Wine core DLL later | Broken container | `extract-wine.sh` refuses names in a deny list (group 1) and anything with a unixlib |
| Licence compliance | LGPL violation on push | Source release asset, `SOURCE.md` and `COPYING.LIB` are acceptance criteria for publishing |

## Phased task checklist

### Phase 1: tier 1 image on ltsc2022

- [x] Create `nano-server-wine-tools/` with `Dockerfile`, `build.cmd`, `README.md`, `.gitignore`, `tools.txt`, `extract-wine.sh`, `fetch-wine.ps1`, `scripts/Test-PeImports.ps1`, `tests/` and `licenses/`.
- [x] `extract-wine.sh` with the hash check, the unixlib refusal and the core-DLL deny list.
- [x] `fetch-wine.ps1` for local builds; `build.cmd` calls it if `wine-pe\` is empty.
- [x] `tests/run-tests.cmd` with tests 1 to 16.
- [x] Acceptance: `build.cmd` with `WINDOWS_VERSION=2022` builds; `docker run --rm windows-nano-wine-tools:2022 C:\tests\run-tests.cmd` exits 0; the build fails if one entry in `tools.txt` is replaced with `cmd.exe` (proves the import check works).

### Phase 2: CI and the other Windows versions

- [x] Add `.github/workflows/wine-tools-container.yml`.
- [x] Acceptance: `extract-wine` and all three matrix legs are green on the self-hosted runner, with TAP artifacts uploaded.
- [x] Retest `timeout` with `-t`. Try `cscript` with app-local `jscript.dll` and `vbscript.dll` registered by `regsvr32`, and record the result in the README.

### Phase 3: build from source

- [x] Add the option C job, which builds only the listed programs, and compare its import tables with option A's.
- [ ] Switch the image to option C if the imports match and the tests pass. Attach the build log to the release.
- [ ] Acceptance: the image's `SOURCE.md` points at the exact tarball and the `configure` line that produced the binaries.

### Phase 4: publish

- [ ] Release with `wine-11.0.tar.xz` and `SOURCE.md`. Push to Docker Hub only when the user asks.
- [ ] Acceptance: the Docker Hub description names the Wine version and links the source release.

## Implementation notes

Implemented on branch `impl/wine-binaries` (PR #21). All five CI jobs are green: `extract-wine`, `build-from-source`, and `build-and-test` on ltsc2019, ltsc2022 and ltsc2025. The import check passes for all nine tools on all three bases, and `run-tests.cmd` reports 27 of 27 checks passing on each. Deviations from the plan:

- **`SOURCE.md` location:** it is `nano-server-wine-tools/SOURCE.md`, not `licenses/SOURCE.md`. `licenses/` also holds Wine's `LICENSE` file next to `COPYING.LIB` and `AUTHORS`. All four are copied into `C:\Program Files\wine-tools\`. Their hashes match the files in `wine-11.0.tar.xz`, and the tarball's SHA-256 (`c07a6857933c1fc60dff5448d79f39c92481c1e9db5aa628db9d0358446e0701`) is recorded in `SOURCE.md`.
- **No release or source mirror:** no GitHub release was created. `SOURCE.md` points at the WineHQ tarball and says that a mirror is still needed before the image is published. Phase 4 is still open.
- **Artifact name:** `wine-pe-11.0` in both jobs (the plan's YAML used `wine-pe`).
- **Test step:** the TAP comes from `docker run --rm` stdout. It is printed in the log and saved as `results-<version>.tap` for the artifact, with no `docker cp`. Builds and test runs are retried once on `hcs ... context deadline exceeded`. Builds use `--memory 4g` and the job has `timeout-minutes: 60`. `pull_request` is not limited to `main`, so PRs into plan branches are built.
- **Check stage user:** pwsh is unpacked under `C:\Users\ContainerUser` and the check runs as the default `ContainerUser`, not `ContainerAdministrator`. The final stage creates `C:\work` as `ContainerAdministrator` and grants `ContainerUser` write access to `C:\work` and `C:\tests`.
- **Test 8:** Wine's `whoami` ends its line with a bare LF, and `findstr`'s `$` only matches before a CR, so the regex is `\\ContainerUser` with no `$`.
- **Test 12 and `start.exe`:** `cmd` parses `start.exe ...` as its built-in `start` followed by `.exe`, which fails with `The system cannot find the file .exe.` (exit code 9059). Wine's `start.exe` works on all three bases when it is called by its full path, `"C:\Program Files\wine-tools\start.exe"`. Tests 12 and 15 call the tools by full path, and the README documents this.
- **Tests 2, 3 and 12** (not run in the prototype) all pass on Wine 11.0.
- **Acceptance check for the import check:** replacing `find.exe` with Wine's `cmd.exe` in the build context fails the `check` stage with `FAIL cmd.exe: 1 unresolved import(s): kernel32.dll!VerifyConsoleIoHandle`. This was run locally on ltsc2022, not in CI.
- **Phase 2 experiments (ltsc2022):** `timeout.exe` works with `docker run -t` and prints `ERROR: not possible to redirect input` without a console. `cscript.exe` with app-local `jscript.dll`, `vbscript.dll` and `scrrun.dll`: all their imports resolve, but `regsvr32` fails (`DllRegisterServer` returns `0x80004002`). With the COM keys and the `.js` association added by hand, `cscript` still prints `Could not create script engine`. Neither tool is shipped. The README records both results.
- **Phase 3:** the `build-from-source` job (`build-wine-from-source.sh`, `compare-imports.sh`) builds the nine programs from `wine-11.0.tar.xz` on `ubuntu-24.04` in about a minute. Their import tables match the WineHQ binaries entry for entry. `find`, `fc`, `where`, `whoami` and `cabarc` are also the same size, while `start`, `tasklist`, `taskkill` and `fsutil` are smaller than the WineHQ builds. The job is informational: the image still uses the WineHQ binaries (option A), so the switch to option C is left open.

## Prototype results

Wine 11.0 x86_64 PE programs, copied unmodified into `C:\wine` on nanoserver ltsc2022:

- **Static import check** of 48 programs against nanoserver's exports: everything resolves except `cmd.exe` (`kernel32!VerifyConsoleIoHandle`), `expand.exe` (two `setupapi` exports), `notepad.exe` (`comctl32` ordinals 410 and 413), `msiexec.exe` (`msi.dll`) and `net.exe` (`netapi32.dll`).
- **Run in the container:** `find` (file mode), `fc`, `where`, `whoami`, `tasklist`, `taskkill`, `start`, `xcopy`, `sort`, `findstr`, `reg`, `attrib`, `hostname`, `fsutil`, `ipconfig`, `ping` and `sc` give correct output. `cmd` and `expand` exit with -1073741511, `net` with -1073741515 and `klist` with -1073741819. `robocopy`, `certutil`, `icacls`, `cacls`, `makecab`, `setx`, `subst`, `shutdown`, `wevtutil` and `schtasks` are stubs.
- `WINEDEBUG=-all` stops the `fixme:` output.

## Sources

- WineHQ Ubuntu packages: <https://dl.winehq.org/wine-builds/ubuntu/>
- Wine source tarballs: <https://dl.winehq.org/wine/source/11.0/>
- Wine source tree: <https://gitlab.winehq.org/wine/wine>
- Wine architecture overview (PE modules and unixlibs): <https://gitlab.winehq.org/wine/wine/-/wikis/Wine-Developer%27s-Guide/Architecture-Overview>
- Wine 8.0 release notes (PE conversion complete, `--enable-archs`): <https://gitlab.winehq.org/wine/wine/-/releases/wine-8.0>
- Wine licensing: <https://wiki.winehq.org/Licensing>
- LGPL-2.1 text: <https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html>
- `winecrt0` debug fallbacks: <https://github.com/wine-mirror/wine/blob/wine-11.0/dlls/winecrt0/debug.c> (lines 53-59 and 156-209)
