# Win32 API tests

`apiprobe.exe` measures which Win32 APIs work in nanoserver, compared with servercore (and later with the ReactOS and Wine augmented images). The design is in [`plans/win32-api-test-framework.md`](../plans/win32-api-test-framework.md).

Every probe runs at one of three levels:

- **L1 load:** `LoadLibraryExW(<dll>, LOAD_LIBRARY_SEARCH_SYSTEM32)` succeeds. One test per line of `data/<version>/dlls.txt`.
- **L2 resolve:** `GetProcAddress` finds every export listed in `data/<version>/exports/<dll>.txt`. One test per DLL; each missing export is listed in the test output and in `results.jsonl`.
- **L3 call:** a short behavioural check, hand-written in `src/probes_*.c` (`apiprobe.exe --list` prints them all).

Each probe runs in a child process (`apiprobe.exe --child <id>`, or a batch of 50 DLLs for L1 and L2) with a timeout, so a crash or a hang becomes a `crash` or `timeout` result and the run goes on.

## Layout

| Path | What it is |
| --- | --- |
| `src/` | `apiprobe.c` (runner, child protocol, JUnit, JSONL and TAP writers, baselines), `probes_*.c`, `Makefile` |
| `data/<version>/` | L1 and L2 inventory of servercore `System32`, made by `scripts/New-ApiInventory.ps1` |
| `expectations/<target>-<version>.txt` | baselines: every probe that is not expected to be `ok` |
| `targets.json` | the images under test |
| `Dockerfile`, `build.cmd` | the thin probe layer that goes on top of a target image |
| `scripts/Resolve-Target.ps1` | target name to base image (builds `build_folder` targets, skips missing ones) |
| `scripts/ConvertTo-ApiMatrix.ps1` | merges `results.jsonl` files into `api-matrix.md` |

## Build

`apiprobe.exe` is cross-compiled with MinGW-w64 on Linux or WSL:

```sh
sudo apt-get install gcc-mingw-w64-x86-64 make
make -C api-tests/src        # writes api-tests/bin/apiprobe.exe
```

It may import only `kernel32.dll` and `msvcrt.dll`, so it starts on every image. Every other function is reached with `LoadLibraryExW` and `GetProcAddress` (the `NEED` and `NEEDT` macros in `src/probes.h`). CI checks the import table with `objdump -p`. Do not call `htons`, `VariantInit` or other DLL functions directly in a probe.

Without a Linux toolchain, download the `apiprobe` artifact of a CI run into `api-tests/bin/`.

## Run locally

```bat
cd api-tests
set TARGET=nanoserver
set WINDOWS_VERSION=2022
build.cmd
docker run --name apiprobe api-probe:nanoserver-2022 "C:\api-tests\apiprobe.exe --target nanoserver --windows-version 2022 --junit C:\results\results.xml --jsonl C:\results\results.jsonl --baseline C:\api-tests\expectations\nanoserver-2022.txt"
docker cp apiprobe:C:\results .
docker rm apiprobe
```

Useful options: `--level 3` (L3 only), `--filter "L3 kernel32.*,L1 wininet"` (comma separated globs over the probe ids), `--timeout-ms 10000`, `--network` (probes that need the internet; they report `skip` without it).

## Results

- **TAP** on stdout: `ok 17 - L3 kernel32.CreateFileW # baseline ok`, `not ok 18 - ... # error 120 (baseline ok)`.
- **JUnit** (`--junit`): one `testsuite` per DLL and level, one `testcase` per probe. A result equal to the baseline is a pass (`ok`) or `skipped` (anything else); a worse result is a `failure`.
- **JSON Lines** (`--jsonl`): one object per result, with `target`, `windows_version`, `os_build`, `level`, `dll`, `function`, `check`, `status`, `win32_error`, `ms`, `baseline` and `verdict`.

Statuses, in severity order: `ok` < `skip` < `error` < `missing-export` < `missing-dll` < `timeout` < `crash`. Only a move to the right is a regression; `skip` (no `--network`) is never one.

## Baselines

`expectations/<target>-<version>.txt` has one line per probe that is not expected to be `ok`:

```text
L1 wininet = missing-dll
L2 kernel32!CreatePseudoConsoleAsUser = missing-export
L3 user32.CreateWindowExW = error
```

A probe that is not listed is expected to be `ok`. The exit code is 1 when any result is worse than its baseline. A result that is better prints a `::warning::` asking for the baseline to be updated.

To update a baseline, run with `--write-baseline <file>`. CI always does this, so the `api-results-<target>-<version>` artifact of every run holds a `baseline-<target>-<version>.txt` that can be reviewed and copied over `expectations/`. Base images change monthly, so update baselines in their own PR and check the `os_build` in the header line.

## Regenerating the inventory

`data/` changes only when Microsoft ships a new LTSC base. On a Windows host with Docker in Windows-containers mode:

```powershell
./api-tests/scripts/New-ApiInventory.ps1 -WindowsVersion 2019,2022,2025
```

It starts a servercore container per version, parses the PE export directory of every `System32\*.dll` with Windows PowerShell, and writes `dlls.txt`, `exports/<dll>.txt` and `source.txt` (image, OS build, and the DLLs left out with the reason: 32-bit, native subsystem, not a DLL, deny list).
