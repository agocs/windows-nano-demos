# Plan: Win32 API test framework for nanoserver and related images

## Goal

Build a repeatable way to measure which Win32 APIs work in nanoserver, compared with servercore and with the augmented images from `plans/reactos-binaries.md` and `plans/wine-binaries.md`. Each run produces JUnit XML for GitHub, plus a machine-readable compatibility matrix (API by image by Windows version). Runs happen on the self-hosted `[self-hosted, windows, docker]` runner.

## Summary of decisions

- **Three levels, one runner.** A small C program, `apiprobe.exe`, checks each API at three levels:
  - **L1 load:** `LoadLibraryExW` of the DLL succeeds.
  - **L2 resolve:** `GetProcAddress` finds the export. This catches nanoserver's reverse forwarders, which export a name that then forwards to an API set that does not exist.
  - **L3 call:** a short behavioural check of the function.
- **Wide coverage from data, deep coverage from code.** L1 and L2 are generated from data files: every DLL and export of servercore's `System32`, collected once per Windows version. L3 probes are hand-written C functions, about 120 of them at first (see [Initial API coverage list](#initial-api-coverage-list)).
- **Crash isolation.** The parent `apiprobe.exe` runs each probe in a child process (`apiprobe.exe --child <probe-id>`) with a timeout. A probe that crashes or hangs is recorded as `crash` or `timeout`, and the run goes on.
- **Toolchain:** cross-compile on `ubuntu-latest` with MinGW-w64 (`x86_64-w64-mingw32-gcc`, Ubuntu 24.04 package `gcc-mingw-w64-x86-64`). The result is uploaded as an artifact, the same pattern as the Wine plan. The binary may **only** import `kernel32.dll` and `msvcrt.dll`, so it starts on any of the images. Everything else is reached through `LoadLibraryExW` and `GetProcAddress`. A CI step checks this with `x86_64-w64-mingw32-objdump -p`. MSVC in a servercore build stage was rejected: the Build Tools installer is large, it needs servercore, and it buys nothing here.
- **Output:** JUnit XML (`results.xml`) for the GitHub test reporter, TAP on stdout for people reading logs, and JSON Lines (`results.jsonl`) for the matrix report.
- **Pass and fail are measured against a baseline.** Many APIs are expected to be missing in nanoserver. Each target has a checked-in expectations file. CI fails only when a result is worse than the baseline. Improvements produce a warning that asks for the baseline to be updated.
- **Wine's conformance suite is phase 3.** The `winetest64.exe` driver refuses to run in nanoserver (`Error: Tests must be run on a visible desktop`, seen on ltsc2022), but `-x DIR` extraction works (333 test modules). Phase 3 adds our own driver that runs the extracted `<dll>_test.exe <unit>` files and converts their output to JUnit.

## Directory layout

- `api-tests/`
  - `README.md`: how to run locally, and how to read and update baselines
  - `Dockerfile`: the thin probe layer that goes on top of each target image
  - `build.cmd`: builds the probe layer on top of one target for local runs
  - `targets.json`: the images to test
  - `src/`: `apiprobe.c` (runner, child dispatch, output writers), `probes_*.c` (one file per DLL family), `probes.h` (the probe table macro), `Makefile`
  - `data/<windows-version>/dlls.txt` and `data/<windows-version>/exports/<dll>.txt`: the L1 and L2 inventories, generated from servercore
  - `expectations/<target>-<windows-version>.txt`: the baselines
  - `scripts/New-ApiInventory.ps1`: makes `data/` from a servercore image
  - `scripts/ConvertTo-ApiMatrix.ps1`: merges `results.jsonl` files into `api-matrix.md`
  - `scripts/Invoke-WineTests.ps1`: phase 3
- `.github/workflows/api-tests.yml`

## The runner: `apiprobe.exe`

### Command line

```text
apiprobe.exe [--level 1|2|3|all] [--filter <glob>] [--data C:\api-tests\data] [--timeout-ms 10000]
             [--junit C:\results\results.xml] [--jsonl C:\results\results.jsonl]
             [--target <name>] [--windows-version <v>] [--network]
             [--baseline <file>] [--write-baseline <file>]
apiprobe.exe --child <probe-id>        (internal: run one probe, exit code is the status)
apiprobe.exe --list                    (print every probe id)
```

### Probe table

```c
/* probes.h */
typedef enum { ST_OK, ST_MISSING_DLL, ST_MISSING_EXPORT, ST_ERROR, ST_CRASH, ST_TIMEOUT, ST_SKIP } status_t;
typedef struct { status_t status; DWORD win32_error; char detail[512]; } result_t;
typedef void (*probe_fn)(result_t *r);
typedef struct { const char *id, *dll, *function, *check; int needs_network; probe_fn fn; } probe_t;
#define PROBE(id, dll, fn, check) static void probe_##id(result_t *r); /* registered in probes_table.c */
```

Helper rules for every L3 probe:

- Resolve every function through `need(r, "dll", "Name")`. It returns `NULL` and sets `ST_MISSING_DLL` or `ST_MISSING_EXPORT` on failure, so a probe never crashes on a missing API.
- Clean up everything it creates: temp files under `%TEMP%\apiprobe\<id>`, registry keys under `HKCU\Software\apiprobe`, sockets, handles.
- Do no network I/O unless `--network` is given. Probes that need it set `needs_network = 1` and report `ST_SKIP` without it.
- Never block on UI. Never call `MessageBox` or `DialogBox`. Use message-only windows (`HWND_MESSAGE`) for window tests.

### Child process protocol

- The parent starts `apiprobe.exe --child <id>` with stdout and stderr on pipes and `CREATE_NO_WINDOW`, then waits up to `--timeout-ms`.
- The child writes one line of JSON (`{"status":"ok","win32_error":0,"detail":"..."}`) to stdout and exits 0.
- If the exit code is an NTSTATUS such as `0xC0000005`, the parent records `crash` with the code. If the wait times out, the parent calls `TerminateProcess` and records `timeout`.
- L1 and L2 are cheap, so they run in batches of 50 DLLs per child. A crash in `DllMain` only loses that batch, and the parent re-runs that batch one DLL at a time to find the culprit.

### L1 and L2 inventory

`scripts/New-ApiInventory.ps1` runs in a servercore container of the same Windows version (pwsh 7 zip unpacked into it):

1. `dlls.txt`: every `*.dll` in `C:\Windows\System32` (1,398 on ltsc2022), minus a deny list of DLLs with load-time side effects (drivers with a `.dll` name, `*.mui`, `ntoskrnl`-mode helpers, `hal`).
2. `exports/<dll>.txt`: the export names of each DLL, from the PE export directory (no tools needed, parse the PE in pwsh; the prototype for the ReactOS plan has a parser that does this).
3. Check the files in once per Windows version. They change only when Microsoft ships a new LTSC base.

L1 records `ok` or `missing-dll` with `GetLastError` (126 means not found, 127 means an import of the DLL is missing, 193 means a bad image). L2 records `ok` or `missing-export` for every export. Forwarded exports are resolved by `GetProcAddress`, so a forwarder that points at a missing API set shows up as `missing-export`.

### Output formats

JUnit (one `testsuite` per DLL and level, one `testcase` per probe):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="apiprobe nanoserver ltsc2022" tests="3" failures="1" skipped="1">
  <testsuite name="kernel32.L3" tests="2" failures="1" skipped="0">
    <testcase classname="nanoserver-2022.kernel32" name="CreateFileW: create, write, read back" time="0.004"/>
    <testcase classname="nanoserver-2022.kernel32" name="CreatePseudoConsole: create 80x25 conpty" time="0.010">
      <failure message="error (win32 120)">expected ok by baseline</failure>
    </testcase>
  </testsuite>
  <testsuite name="wininet.L1" tests="1" failures="0" skipped="1">
    <testcase classname="nanoserver-2022.wininet" name="load" time="0.001">
      <skipped message="missing-dll (win32 126), expected by baseline"/>
    </testcase>
  </testsuite>
</testsuites>
```

Mapping: a result that matches the baseline and is `ok` is a pass. A result that matches the baseline and is not `ok` is `skipped`, with the status in the message. A result that is worse than the baseline is a `failure`. A result that is better than the baseline is a pass, with `<system-out>improved: was missing-export</system-out>`, and the parent prints a GitHub `::warning::` line.

JSON Lines (one object per probe result):

```json
{"target":"nanoserver","windows_version":"2022","os_build":"20348.5773","level":3,"dll":"kernel32","function":"CreatePseudoConsole","check":"create 80x25 conpty","status":"error","win32_error":120,"ms":10,"baseline":"ok"}
```

TAP on stdout: `ok 17 - kernel32 CreateFileW # baseline ok` or `not ok 18 - kernel32 CreatePseudoConsole # error 120`.

### Baselines

`expectations/<target>-<windows-version>.txt` holds one line per probe id that is **not** expected to be `ok`, for example `L1 wininet = missing-dll` and `L3 kernel32.CreatePseudoConsole = error`. A probe id that is not listed is expected to be `ok`. `apiprobe.exe --write-baseline <file>` writes the file from a run. The first run of each target creates its baseline, and a human reviews it in the PR.

Severity order for "worse than": `ok` < `skip` < `error` < `missing-export` < `missing-dll` < `timeout` < `crash`. The order exists only for comparisons. Any change counts as a difference, and only a move to the right fails.

## Initial API coverage list

Each entry is an L3 probe: `dll!Function`, then the behaviour it checks. Expected nanoserver results come from the ReactOS plan audit (forwarders and `regsvr32` load probe on ltsc2022). Entries marked (N) need `--network`.

### kernel32 and kernelbase

- `GetVersionExW` and `ntdll!RtlGetVersion`: the major, minor and build agree, and the build matches `os_build`
- `GetNativeSystemInfo`: `PROCESSOR_ARCHITECTURE_AMD64`
- `CreateFileW`, `WriteFile`, `ReadFile`, `SetFilePointerEx`, `GetFileSizeEx`: round trip of 64 KiB
- `FindFirstFileExW` with `FindExInfoBasic`: finds the probe's temp file
- `GetFinalPathNameByHandleW`: returns a `\\?\C:\` path
- `CreateHardLinkW` and `CreateSymbolicLinkW` (`SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE`): the link exists afterwards
- `ReadDirectoryChangesW`: sees a file created by a second thread within 2 s
- `CreateProcessW`: `cmd /c exit 7` gives exit code 7
- `CreatePipe` and `CreateNamedPipeW`/`ConnectNamedPipe`: a loopback message arrives
- `CreateThread`, `CreateEventW`, `WaitForMultipleObjects`, `CreateWaitableTimerW`
- `VirtualAlloc`, `VirtualProtect`, `FlushInstructionCache`: run a 1-byte `ret` stub
- `CreateJobObjectW` and `AssignProcessToJobObject`: kill-on-close works
- `CreateToolhelp32Snapshot`, `Process32FirstW`: sees its own PID
- `OpenProcess` and `QueryFullProcessImageNameW` on itself
- `GetComputerNameExW` (`ComputerNameDnsHostname`)
- `GetEnvironmentVariableW`, `ExpandEnvironmentStringsW`, `SetEnvironmentVariableW`
- `GetUserDefaultLocaleName`, `GetDateFormatEx`, `GetTimeZoneInformation`, `GetDynamicTimeZoneInformation`
- `WideCharToMultiByte` and `MultiByteToWideChar` with CP_UTF8 and code page 1252
- `GetLogicalDriveStringsW`, `GetDiskFreeSpaceExW`, `GetVolumeInformationW`
- `GetConsoleMode`, `SetConsoleMode` (`ENABLE_VIRTUAL_TERMINAL_PROCESSING`), `GetConsoleScreenBufferInfo`: run with and without `docker run -t`
- `CreatePseudoConsole`, `ResizePseudoConsole`, `ClosePseudoConsole`: start `cmd /c echo hi` in a conpty and read `hi` back. This is the main blocker for TUI tools.
- `LoadLibraryExW` with `LOAD_LIBRARY_SEARCH_SYSTEM32`, `AddDllDirectory`
- `QueryPerformanceCounter`, `GetTickCount64`, `GetSystemTimePreciseAsFileTime`

### advapi32

- `OpenProcessToken`, `GetTokenInformation(TokenUser)`, `LookupAccountSidW`: `User Manager\ContainerUser`
- `ConvertSidToStringSidW`, `CreateWellKnownSid(WinBuiltinAdministratorsSid)`
- `RegOpenKeyExW` and `RegQueryValueExW`: `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\CurrentBuild`
- `RegCreateKeyExW`, `RegSetValueExW`, `RegDeleteTreeW` under `HKCU\Software\apiprobe`
- `GetUserNameW`
- `CryptAcquireContextW(PROV_RSA_AES)` and `CryptGenRandom`
- `OpenSCManagerW` and `EnumServicesStatusExW`: at least one service
- `RegisterEventSourceW` and `ReportEventW`: the call returns TRUE
- `AdjustTokenPrivileges(SeChangeNotifyPrivilege)`

### Crypto: bcrypt, ncrypt, crypt32

- `bcrypt!BCryptGenRandom`, `BCryptOpenAlgorithmProvider(SHA256)`, `BCryptHash`: the known digest of `abc`
- `ncrypt!NCryptOpenStorageProvider(MS_KEY_STORAGE_PROVIDER)`
- `crypt32!CertOpenSystemStoreW("ROOT")` and `CertEnumCertificatesInStore`: more than 0 certificates
- `crypt32!CryptStringToBinaryA(CRYPT_STRING_BASE64)`

### user32 (mostly stubs in nanoserver)

- `GetSystemMetrics(SM_CXSCREEN)`
- `GetProcessWindowStation` and `GetUserObjectInformationW(UOI_FLAGS)`: records `WSF_VISIBLE` (this is what stops `winetest.exe`)
- `RegisterClassExW` and `CreateWindowExW(HWND_MESSAGE)`, then `PostMessageW` and `GetMessageW` round trip
- `LoadStringW` from a resource in `apiprobe.exe`
- `CharUpperW`, `wsprintfW`
- `OpenClipboard`, `SetClipboardData`, `GetClipboardData`
- `GetKeyboardLayout`, `MapVirtualKeyW`

### gdi32

- `CreateCompatibleDC(NULL)`, `CreateCompatibleBitmap`, `SelectObject`
- `GetStockObject(DEFAULT_GUI_FONT)`, `CreateFontIndirectW`

### shell32, shlwapi and shcore

- `shell32!SHGetKnownFolderPath(FOLDERID_RoamingAppData)`, `SHGetFolderPathW(CSIDL_PROFILE)`
- `shell32!CommandLineToArgvW`: splits `a "b c" d` into 3
- `shell32!ShellExecuteExW` with verb `open` on `cmd.exe /c exit 0`
- `shell32!SHFileOperationW(FO_COPY)` of a temp file
- `shlwapi!PathCombineW`, `PathFileExistsW`, `StrStrIW`, `SHGetValueW`
- `shcore!GetDpiForMonitor`: load and resolve only

### COM: ole32, combase, oleaut32

- `CoInitializeEx(COINIT_MULTITHREADED)`, `CoCreateGuid`, `StringFromGUID2`
- `CoCreateInstance` of: `CLSID_WbemLocator` (WMI, then `ConnectServer("ROOT\\CIMV2")` and `SELECT Caption FROM Win32_OperatingSystem`), `CLSID_ShellLink`, `CLSID_TaskScheduler`, `CLSID_FileSystemObject` (`scrrun`), `CLSID_DOMDocument60` (`msxml6`), `CLSID_XMLHTTPRequest`. Each records whether the class is registered and creatable.
- `oleaut32!SysAllocString`, `VariantChangeType(VT_BSTR to VT_I4)`, `SafeArrayCreate`

### Networking: ws2_32, iphlpapi, dnsapi, winhttp, wininet, urlmon

- `ws2_32!WSAStartup`, `socket`, `bind(127.0.0.1:0)`, `listen`, `connect`, `send`, `recv`: TCP loopback echo
- `ws2_32!getaddrinfo("localhost")`, `GetAddrInfoW("github.com")` (N)
- `ws2_32!WSAPoll`, and `ioctlsocket(FIONBIO)`
- AF_UNIX socket under `%TEMP%`
- `iphlpapi!GetAdaptersAddresses`: at least one adapter
- `iphlpapi!GetExtendedTcpTable`
- `dnsapi!DnsQuery_W("github.com", DNS_TYPE_A)` (N)
- `winhttp!WinHttpOpen`, `WinHttpCrackUrl`; `GET https://www.msftconnecttest.com/connecttest.txt` gives `Microsoft Connect Test` (N)
- `wininet!InternetOpenW`: expected `missing-dll` in nanoserver
- `urlmon!URLDownloadToFileW`: expected `missing-dll` in nanoserver

### Diagnostics and process info: dbghelp, psapi, version, pdh, wevtapi

- `dbghelp!SymInitializeW` and `SymFromAddrW` on a function in `apiprobe.exe`
- `dbghelp!MiniDumpWriteDump` of a child process to `%TEMP%`
- `psapi!EnumProcesses`, `GetModuleFileNameExW`
- `version!GetFileVersionInfoSizeW` and `VerQueryValueW` on `C:\Windows\System32\kernelbase.dll`
- `pdh!PdhOpenQueryW` and `PdhAddEnglishCounterW("\\Processor(_Total)\\% Processor Time")`
- `wevtapi!EvtQuery("System")`

### Accounts, setup and multimedia: netapi32, userenv, secur32, setupapi, winmm

- `netapi32!NetGetJoinInformation`: expected `missing-dll` in nanoserver
- `userenv!GetUserProfileDirectoryW`
- `secur32!GetUserNameExW(NameSamCompatible)`, `AcquireCredentialsHandleW("Negotiate")`
- `setupapi!SetupDiGetClassDevsW(DIGCF_ALLCLASSES)`
- `winmm!timeGetTime`, `timeBeginPeriod`

### C runtimes

- `msvcrt!_wfopen`, `setlocale(LC_ALL, ".UTF8")`, `strftime`, `_beginthreadex`
- `ucrtbase!_wfopen` and `setlocale`
- `vcruntime140` and `msvcp140`: L1 only (expected `missing-dll` in nanoserver; PHP and others copy `vcruntime140.dll` in)

### Load-only (L1 and L2 with no L3)

`comctl32`, `comdlg32`, `uxtheme`, `dwmapi`, `gdiplus`, `windowscodecs`, `d3d11`, `dxgi`, `opengl32`, `riched20`, `msi`, `mscoree`, `odbc32`, `winscard`, `credui`, `taskschd`, `clbcatq`, `avrt`, `hid`, `winusb`. Most are expected `missing-dll` in nanoserver, according to the `regsvr32` probe in the ReactOS plan.

## The probe layer image

The images under test must not be changed, so `api-tests/Dockerfile` adds a thin layer on top of each target:

```dockerfile
ARG WINDOWS_VERSION=2022
ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64
FROM ${BASE_IMAGE}
ARG WINDOWS_VERSION
COPY bin/apiprobe.exe C:/api-tests/apiprobe.exe
COPY data/${WINDOWS_VERSION}/ C:/api-tests/data/
COPY expectations/ C:/api-tests/expectations/
ENV APIPROBE_WINDOWS_VERSION=${WINDOWS_VERSION}
ENTRYPOINT ["cmd", "/S", "/C"]
```

`bin/apiprobe.exe` comes from the build artifact in CI, or from `make` on a Linux or WSL machine for local builds. `build.cmd` takes `TARGET` and `WINDOWS_VERSION` and looks up `BASE_IMAGE` in `targets.json`.

`targets.json`:

```json
{
  "targets": [
    { "name": "nanoserver", "base_image": "mcr.microsoft.com/windows/nanoserver:ltsc{v}-amd64" },
    { "name": "servercore", "base_image": "mcr.microsoft.com/windows/servercore:ltsc{v}-amd64" },
    { "name": "reactos-tools", "build_folder": "nano-server-reactos-tools", "image": "windows-nano-reactos-tools:{v}" },
    { "name": "wine-tools", "build_folder": "nano-server-wine-tools", "image": "windows-nano-wine-tools:{v}" }
  ]
}
```

A target with `build_folder` is built first with `docker build --build-arg WINDOWS_VERSION={v}` in that folder, and the target is skipped (with a notice) if the folder does not exist yet. That way this framework can land before the ReactOS and Wine images do.

## CI workflow

`.github/workflows/api-tests.yml`:

```yaml
name: Win32 API tests
on:
  push:
    branches: [main]
    paths: ['api-tests/**', '.github/workflows/api-tests.yml']
  pull_request:
    branches: [main]
    paths: ['api-tests/**', '.github/workflows/api-tests.yml']
  workflow_dispatch:
    inputs:
      network:
        description: Run probes that need the network
        type: boolean
        default: false
permissions:
  contents: read
  checks: write
jobs:
  build-probe:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: sudo apt-get update && sudo apt-get install -y gcc-mingw-w64-x86-64 make
      - run: make -C api-tests/src
      - name: Imports must be kernel32 and msvcrt only
        run: |
          dlls=$(x86_64-w64-mingw32-objdump -p api-tests/bin/apiprobe.exe | awk '/DLL Name:/ {print tolower($3)}' | sort -u | tr '\n' ' ')
          echo "imports: $dlls"
          test "$dlls" = "kernel32.dll msvcrt.dll "
      - uses: actions/upload-artifact@v4
        with:
          name: apiprobe
          path: api-tests/bin/apiprobe.exe
  probe:
    needs: build-probe
    if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository
    runs-on: [self-hosted, windows, docker]
    strategy:
      fail-fast: false
      matrix:
        windows-version: ['2019', '2022', '2025']
        target: [nanoserver, servercore, reactos-tools, wine-tools]
    defaults:
      run:
        shell: pwsh
    env:
      IMAGE: api-probe:${{ matrix.target }}-${{ matrix.windows-version }}-${{ github.sha }}
      CTR: api-${{ github.run_id }}-${{ matrix.target }}-${{ matrix.windows-version }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: apiprobe
          path: api-tests/bin
      - name: Resolve or build the target image
        id: target
        run: ./api-tests/scripts/Resolve-Target.ps1 -Name ${{ matrix.target }} -WindowsVersion ${{ matrix.windows-version }}
        # writes base_image=... and skip=true|false to $env:GITHUB_OUTPUT
      - name: Build the probe layer
        if: steps.target.outputs.skip != 'true'
        working-directory: api-tests
        run: |
          docker build --build-arg WINDOWS_VERSION=${{ matrix.windows-version }} --build-arg BASE_IMAGE=${{ steps.target.outputs.base_image }} -t $env:IMAGE .
          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
      - name: Run probes
        if: steps.target.outputs.skip != 'true'
        run: |
          $net = '${{ inputs.network }}' -eq 'true' ? '--network' : ''
          docker run --name $env:CTR $env:IMAGE "C:\api-tests\apiprobe.exe --level all --target ${{ matrix.target }} --windows-version ${{ matrix.windows-version }} --junit C:\results\results.xml --jsonl C:\results\results.jsonl --baseline C:\api-tests\expectations\${{ matrix.target }}-${{ matrix.windows-version }}.txt $net"
          $rc = $LASTEXITCODE
          New-Item -ItemType Directory -Force results | Out-Null
          docker cp "$($env:CTR):C:\results\." results
          exit $rc
      - uses: actions/upload-artifact@v4
        if: always() && steps.target.outputs.skip != 'true'
        with:
          name: api-results-${{ matrix.target }}-${{ matrix.windows-version }}
          path: results/
      - name: Clean up
        if: always()
        run: |
          docker rm -f $env:CTR 2>$null
          docker rmi -f $env:IMAGE 2>$null
          exit 0
  report:
    needs: probe
    if: always()
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          pattern: api-results-*
          path: results
      - uses: dorny/test-reporter@v2
        with:
          name: Win32 API results
          path: 'results/**/results.xml'
          reporter: java-junit
          fail-on-error: false
      - name: Compatibility matrix
        shell: pwsh
        run: |
          ./api-tests/scripts/ConvertTo-ApiMatrix.ps1 -Path results -Out api-matrix.md
          Get-Content api-matrix.md | Add-Content $env:GITHUB_STEP_SUMMARY
      - uses: actions/upload-artifact@v4
        with:
          name: api-matrix
          path: api-matrix.md
```

Notes:

- The runner is a container that talks to the host daemon over the named pipe, so the workspace cannot be bind-mounted. Results come out through `docker cp` from the stopped container.
- Servercore images are large (several GB per version). The first run pulls them, and later runs use the host's cache. Keep `docker rmi` limited to the probe layer image and never remove the base.
- `report` runs on `ubuntu-latest` so that the self-hosted runner is not tied up, and because `dorny/test-reporter` and `pwsh` are both available there.
- `ConvertTo-ApiMatrix.ps1` writes a Markdown table with one row per `dll!Function` and one column per `target-version`, with cells `ok`, `missing-dll`, `missing-export`, `error <code>`, `crash` or `timeout`. A second table counts L1 and L2 per DLL, for example `kernel32 L2: 1,243/1,598`.

## Phase 3: Wine's conformance tests

What the prototype found on nanoserver ltsc2022:

- The daily build from `https://gitlab.winehq.org/wine/wine/-/jobs/artifacts/master/raw/winetest64.exe?job=build-daily-winetest` (87,700,896 bytes; `--version` printed `7692c6213e2c`; SHA-256 `EDE3757FDC1F9B39023FED01668A9D52484C8989254C6A7C7245D00742D032BA`) imports only `advapi32`, `comctl32`, `kernel32`, `msvcrt`, `user32`, `version` and `wsock32`, and starts in nanoserver.
- `winetest64.exe -h` works. The driver supports `-J FILE` (JUnit XML) and `-o FILE` (report without submitting).
- `winetest64.exe -c -o ... -J ...` stops with `Error: Tests must be run on a visible desktop`. The check is `running_on_visible_desktop()` in `programs/winetest/main.c`, which needs `WSF_VISIBLE` on the window station. The check cannot be turned off from the command line.
- `winetest64.exe -x C:\wt` works and extracts 333 test modules (`advapi32_test.exe`, `kernel32_test.exe` and so on).

Plan:

1. Pin the daily `winetest64.exe` by uploading the copy we test with as a GitHub release asset (the GitLab URL always points at the latest build). Record the SHA-256 and the `--version` commit in `api-tests/winetest.txt`.
2. Add `scripts/Invoke-WineTests.ps1`. The probe layer gets pwsh 7 (`PowerShell-7.6.9-win-x64.zip`) and the pinned `winetest64.exe` only when `--wine` is selected. The script:
   - runs `winetest64.exe -x C:\wt`
   - for each module in `api-tests/winetest-units.txt` (for example `kernel32:file`, `kernel32:path`, `kernel32:process`, `kernel32:sync`, `kernel32:pipe`, `kernel32:locale`, `advapi32:registry`, `advapi32:security`, `advapi32:service`, `ws2_32:sock`, `shlwapi:path`, `ole32:compobj`, `oleaut32:vartest`, `ntdll:file`, `ntdll:reg`, `msvcrt:file`, `ucrtbase:misc`, `bcrypt:bcrypt`, `crypt32:cert`, `iphlpapi:iphlpapi`, `winhttp:url`), runs `C:\wt\<dll>_test.exe <unit>` with `WINETEST_PLATFORM=windows`, `WINETEST_INTERACTIVE=0`, `WINETEST_REPORT_SUCCESS=0`, `WINETEST_TIME=1` and a 120 s timeout
   - parses `<file>.c:<line>: Test failed: <msg>`, `Test succeeded inside todo block`, `Tests skipped: <msg>` and the summary line `<unit>: <n> tests executed (<t> marked as todo, <f> failures), <s> skipped.`
   - writes JUnit the same way the driver's `-J` writer does (`testsuite name="<dll>:<unit>"`, one `testcase` per failure, and one `testcase name="<n> succeeding tests"`), so results look the same whether they come from `winetest.exe -J` on servercore or from our driver on nanoserver.
3. Compare with servercore by running the same units there. On servercore the real driver may pass the desktop check. If it does, use `winetest64.exe -c -o report.txt -J results.xml <units>` there as a cross-check of our parser.
4. Baselines work the same way: `expectations/wine-<target>-<v>.txt` lists units with a known failure count.

Running the individual extracted test executables in nanoserver has **not** been tried yet. Phase 3 starts with that spike.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| A probe crashes or hangs | Lost results | One child process per probe, a timeout, and batch splitting for L1 and L2 |
| `DllMain` side effects during L1 on 1,000+ DLLs | Crashes, hangs, popups | Deny list, batches, `SetErrorMode(SEM_FAILCRITICALERRORS)`, `CREATE_NO_WINDOW`; run as `ContainerUser` |
| The runner binary itself fails to load on some target | No results at all | Imports limited to `kernel32` and `msvcrt`, checked in CI |
| Flaky network probes | Red builds | Network probes only with `--network`, never on PRs |
| Servercore pulls are slow and large | Long first run | Host cache; servercore legs can run only on `push` to main and on `workflow_dispatch` if PR time becomes a problem |
| Baselines drift with monthly base image updates | Spurious failures | `os_build` in every result; the report notes the build; update baselines in a dedicated PR |
| `winetest` daily build changes | Unrepeatable phase 3 results | Pin it as a release asset |
| The Wine test suite assumes a desktop or interactive session | Many skips or failures | Units are picked one by one; baselines record known failures |

## Phased task checklist

### Phase 1: runner and L1, L2 on nanoserver and servercore

- [ ] `api-tests/src`: `apiprobe.c` with the command line, child protocol, JUnit, JSONL and TAP writers, and baseline comparison; `Makefile` for `x86_64-w64-mingw32-gcc -O2 -municode -static-libgcc -o ../bin/apiprobe.exe`.
- [ ] `scripts/New-ApiInventory.ps1`; generate and commit `data/2019`, `data/2022` and `data/2025` from servercore.
- [ ] L1 and L2 levels driven by `data/`.
- [ ] `Dockerfile`, `build.cmd`, `targets.json`, `scripts/Resolve-Target.ps1`.
- [ ] Acceptance: locally, `api-probe` on `nanoserver` ltsc2022 writes a valid JUnit file (it passes `xmllint --noout` in the report job) with an L1 result for every line of `data/2022/dlls.txt`. `wininet` is `missing-dll` and `kernel32` is `ok`. The objdump check shows only `kernel32.dll` and `msvcrt.dll`.

### Phase 2: L3 probes and CI

- [ ] The L3 probes in [Initial API coverage list](#initial-api-coverage-list), one `probes_<dll>.c` per section.
- [ ] `--write-baseline`; commit baselines for `nanoserver` and `servercore` on all three versions after reviewing them.
- [ ] `.github/workflows/api-tests.yml` with `build-probe`, `probe` and `report`.
- [ ] `scripts/ConvertTo-ApiMatrix.ps1`.
- [ ] Acceptance: the workflow is green on main for `nanoserver` and `servercore` on 2019, 2022 and 2025. The step summary shows the matrix. Changing one baseline line from `missing-dll` to `ok` makes that leg fail, which proves the baseline gate works.

### Phase 3: augmented images and Wine's tests

- [ ] Turn on the `reactos-tools` and `wine-tools` targets once their folders exist, and commit their baselines.
- [ ] The Wine conformance spike described above, then `Invoke-WineTests.ps1` and `winetest-units.txt`.
- [ ] Acceptance: JUnit from `Invoke-WineTests.ps1` for `kernel32:path` on nanoserver and on servercore shows up in the test reporter, and the matrix gains a "Wine units" table.

## Sources

- Wine conformance tests and `winetest.exe`: <https://gitlab.winehq.org/wine/wine/-/wikis/Conformance-Tests> and <https://test.winehq.org/data/>
- `winetest` driver source (`running_on_visible_desktop`, `-J`): <https://gitlab.winehq.org/wine/wine/-/blob/master/programs/winetest/main.c>
- Wine test output format (`wine/test.h`): <https://gitlab.winehq.org/wine/wine/-/blob/master/include/wine/test.h>
- Nanoserver API differences: <https://learn.microsoft.com/en-us/virtualization/windowscontainers/manage-containers/container-base-images>
- Pseudo console API: <https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session>
- JUnit XML schema used by test reporters: <https://github.com/testmoapp/junitxml>
- TAP: <https://testanything.org/tap-version-13-specification.html>
- `dorny/test-reporter`: <https://github.com/dorny/test-reporter>
- MinGW-w64 on Ubuntu: <https://packages.ubuntu.com/noble/gcc-mingw-w64-x86-64>
