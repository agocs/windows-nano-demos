# Plan: console and TUI text editors to try in nanoserver

## Goal

Find out which terminal text editors run in a nanoserver container, so that the dev images in this repo can offer more than `micro`. Each candidate below has its Windows build source, the blockers we expect on nanoserver, a priority, and a non-interactive smoke test that CI can run.

Out of scope here, because they are being done separately: **micro** (already in `nano-server-php` and `nano-server-rust`), **Far Manager**, **vim** and **neovim**.

## How the candidates were checked

- **Static import check.** Each Windows build that is published as a download was fetched, and its PE import table was checked against the exports of nanoserver ltsc2022's own DLLs (`System32\forwarders\*.dll`, `KernelBase.dll`, `ucrtbase.dll`, `msvcrt.dll` and others copied out of `mcr.microsoft.com/windows/nanoserver:ltsc2022-amd64`). This is the same method as `plans/reactos-binaries.md`. The editors were **not** run in the check. The smoke tests below are for the implementing agent.
- **Known nanoserver gaps that matter for editors** (from the ReactOS plan audit):
  - `vcruntime140.dll`, `vcruntime140_1.dll` and `msvcp140.dll` are not in nanoserver, or in servercore. Binaries built with MSVC and the dynamic CRT need these files copied in. `nano-server-php` copies `vcruntime140.dll` from the host.
  - `icu.dll` is in servercore but not in nanoserver.
  - `user32`, `gdi32`, `shell32`, `ole32`, `comdlg32` and `imm32` are reverse forwarders. They load, but a lot of GUI functions forward to API sets that do not exist.
  - There is no GUI, no clipboard (`clip.exe` reports `This function is not supported on this system`) and no WoW64, so 64-bit builds only.
- **Console requirement.** TUI editors need a real console. In CI the runner has no TTY, so `docker run -it` fails with `the input device is not a TTY`. Smoke tests therefore use `--version`, `--help`, batch or headless modes, or the pseudo console harness described in [Interactive smoke test with a pseudo console](#interactive-smoke-test-with-a-pseudo-console).

## Candidate summary

| Editor | Version | Windows build | Import check on ltsc2022 | Expected blockers | Priority |
| --- | --- | --- | --- | --- | --- |
| Microsoft Edit | 2.0.0 | Official zip | Resolves: only `kernel32`, `ntdll` and UCRT API sets | `icu.dll` missing (optional, loaded at run time) | **P1** |
| nano (okibcn port) | 7.2-22.1 | Community zip | Resolves: `advapi32`, `bcrypt`, `kernel32`, `user32`, `winmm` and UCRT | Old (2023); bsdtar extraction bug (see below) | **P1** |
| Helix | 25.07.1 | Official zip | Resolves except `vcruntime140.dll` | Needs `vcruntime140.dll`; needs `runtime\` folder | **P1** |
| ox | 0.7.7 | Official `ox.exe` | Resolves: `msvcrt`, `kernel32`, `ntdll`, `user32`, `shell32`, `ole32`, `userenv`, `ws2_32` | None found | **P2** |
| kibi (kilo clone) | 0.3.3 | Official zips (gnu and msvc) | gnu build resolves; msvc build needs `vcruntime140.dll` | None with the gnu build | **P2** |
| GNU Emacs (`-nw`) | 31.1 | Official GNU zip | Not checked (large) | GUI imports through forwarders; size (92 MB zip) | **P2** |
| Textadept (curses) | 13.1 | Official zip (`textadept-curses.exe`) | Needs `msvcp140`, `vcruntime140`, `vcruntime140_1`; `iconv.dll` is in the zip | VC++ runtime | **P3** |
| Turbo (Turbo Vision editor) | master | No release binaries | n/a | Must be built (CMake and MSVC, or MinGW) | **P3** |
| joe | MSYS2 `joe` package | MSYS2 (msys runtime) | Not checked | Needs `msys-2.0.dll` (Cygwin-style POSIX layer) | **P4** |
| kakoune | 2026.05.21 | None | n/a | POSIX only; no native Windows port | Skip |
| amp | 0.7.1 | None for Windows | n/a | Uses `termion`, which is Unix only | Skip |
| kilo | n/a | None | n/a | POSIX `termios` only (use kibi instead) | Skip |
| mg | n/a | None maintained | n/a | POSIX; no maintained Windows build | Skip |
| ne | n/a | None | n/a | POSIX; Cygwin only | Skip |
| jed | n/a | No maintained 64-bit build found | n/a | S-Lang dependency | Skip |

## Candidates in detail

### Microsoft Edit (P1)

- Source: <https://github.com/microsoft/edit>
- Download: `https://github.com/microsoft/edit/releases/download/v2.0.0/edit-2.0.0-x86_64-windows.zip` (1,152,332 bytes; holds `edit-2.0.0-x86_64-windows\edit.exe`, 329,016 bytes)
- Imports: `kernel32`, `ntdll`, `api-ms-win-core-synch-l1-2-0`, and the UCRT API sets (`api-ms-win-crt-*`). All resolve in nanoserver.
- Expected blockers: Edit loads `icu.dll` at run time for Unicode-aware search and word wrapping, and works without it. Nanoserver has no `icu.dll`. Check that search still works, and record any degraded behaviour.
- Smoke test: `edit --version` exits 0 and prints `2.0.0`. Then run the pseudo console test.
- Install: unzip to `C:\Program Files\edit`, and add it to `PATH`.

### nano, Windows port (P1)

- Source: <https://github.com/okibcn/nano-for-windows> (GNU nano 7.2 built with MinGW against UCRT)
- Download: `https://github.com/okibcn/nano-for-windows/releases/download/v7.2-22.1/nano-for-windows_win64_v7.2-22.1.zip` (285,662 bytes; `nano.exe` is 180,736 bytes)
- Imports: `ADVAPI32`, `bcrypt`, `KERNEL32`, `USER32` (`wsprintfW`, keyboard functions), `WINMM` (`PlaySoundW`) and the UCRT API sets. All the named imports resolve in nanoserver.
- **Extraction bug:** Windows 11's `tar.exe` (bsdtar 3.8.9) extracted `nano.exe` from this zip as 180,736 zero bytes, with no error. `Expand-Archive` extracts it correctly. Nanoserver's `tar` may do the same, so check the `MZ` header (or a SHA-256) after extraction in the Dockerfile. Use 7-Zip, or pwsh `Expand-Archive`, if `tar` fails.
- Expected blockers: the release is from April 2023 and is not updated. Check that `.nanorc` is found under `%USERPROFILE%`.
- Smoke test: `nano --version` prints `GNU nano, version 7.2`. Then run the pseudo console test.

### Helix (P1)

- Source: <https://github.com/helix-editor/helix>
- Download: `https://github.com/helix-editor/helix/releases/download/25.07.1/helix-25.07.1-x86_64-windows.zip` (28,550,028 bytes; `hx.exe` is 22,347,776 bytes, plus the `runtime\` folder)
- Imports: `advapi32`, `bcryptprimitives`, `kernel32`, `ntdll`, `ole32`, `oleaut32`, `shell32`, `user32`, `userenv`, `ws2_32`, the UCRT API sets and **`VCRUNTIME140.dll`**, which nanoserver lacks.
- Fix: copy `vcruntime140.dll` next to `hx.exe`. In CI there is no host `System32` to copy from (the runner is a container), so take it from the Python embeddable zip, which redistributes it: `https://www.python.org/ftp/python/3.14.2/python-3.14.2-embed-amd64.zip` (contains `vcruntime140.dll` and `vcruntime140_1.dll`). For local builds, `build.cmd` can copy it from the host as `nano-server-php/build.cmd` does.
- Set `HELIX_RUNTIME=C:\Program Files\helix\runtime`.
- Smoke tests: `hx --version` prints `helix 25.07.1`. `hx --health` prints the language table, and must not crash when no language servers are installed. `hx --grammar fetch` is **not** run (it needs git and a network).

### ox (P2)

- Source: <https://github.com/curlpipe/ox>
- Download: `https://github.com/curlpipe/ox/releases/download/0.7.7/ox.exe` (5,911,552 bytes, a single file)
- Imports: `msvcrt`, `kernel32`, `ntdll`, `bcryptprimitives`, `ole32`, `shell32`, `user32`, `userenv`, `ws2_32`. All resolve.
- Smoke test: `ox --version`. Then the pseudo console test. ox writes its config to `%USERPROFILE%\.oxrc` on first start, so check that the profile directory is writable as `ContainerUser`.

### kibi (P2)

- Source: <https://github.com/ilai-deutel/kibi> (a kilo clone in Rust with Windows support)
- Download: `https://github.com/ilai-deutel/kibi/releases/download/v0.3.3/kibi-v0.3.3-x86_64-pc-windows-gnu.zip` (238,461 bytes). Use the **gnu** build, which needs only the UCRT API sets, `kernel32` and `ntdll`. The msvc build (`...-x86_64-pc-windows-msvc.zip`) also needs `vcruntime140.dll`.
- Releases come with `.asc` signatures and `.intoto.jsonl` provenance. Check the signature in the build if a key is published.
- Smoke test: `kibi --version`. Then the pseudo console test.

### GNU Emacs, terminal mode (P2)

- Source: <https://ftp.gnu.org/gnu/emacs/windows/emacs-31/>
- Downloads: `emacs-31.1_1.zip` (92,352,392 bytes, with dependencies) or `emacs-31.1_1-nodeps-UCRT64.zip` (63,274,475 bytes, needs MSYS2 UCRT64 DLLs). Use the full zip.
- Expected blockers: `emacs.exe` is the GUI build that can also run with `-nw`. It imports `gdi32`, `user32`, `comdlg32`, `imm32`, `shell32`, `ole32`, `usp10` and others. In nanoserver these are forwarders, and some imported functions may forward to missing API sets, which means a load failure. Run the import check first, and stop if it fails.
- Smoke tests that need no TTY:
  - `emacs --version`
  - `emacs --batch --eval "(princ emacs-version)"` prints `31.1`
  - `emacs --batch -Q --eval "(progn (find-file \"C:/tmp/t.txt\") (insert \"hello\") (save-buffer))"`, then `type C:\tmp\t.txt` contains `hello`
- Then the pseudo console test with `emacs -nw -Q`.

### Textadept, curses version (P3)

- Source: <https://github.com/orbitalquark/textadept>
- Download: `https://github.com/orbitalquark/textadept/releases/download/textadept_13.1/textadept_13.1.win.zip` (22,257,319 bytes; holds `textadept\textadept-curses.exe` and `iconv.dll`)
- Imports: `advapi32`, `kernel32`, `user32`, `ws2_32`, the UCRT API sets, `iconv.dll` (in the zip), and **`msvcp140.dll`, `vcruntime140.dll` and `vcruntime140_1.dll`**.
- Fix: the VC++ runtime DLLs. The Python embeddable zip has `vcruntime140.dll` and `vcruntime140_1.dll` but not `msvcp140.dll`. For phase 1, copy all three from the host in `build.cmd`, the same way `nano-server-php` does, and leave Textadept out of the CI image until there is a CI-friendly source for `msvcp140.dll`.
- Smoke test: `textadept-curses -v` (or `--help`). Then the pseudo console test.

### Turbo (P3)

- Source: <https://github.com/magiblot/turbo> (an editor built on <https://github.com/magiblot/tvision>, which supports the Win32 console natively)
- No release binaries. Build it in a stage: MinGW-w64 cross-compile on `ubuntu-latest` (CMake toolchain file for `x86_64-w64-mingw32`), with `-static` so no MinGW DLLs are needed. Upload the binary as an artifact, the same pattern as `plans/wine-binaries.md`.
- Smoke test: `turbo --help`, then the pseudo console test.

### joe (P4)

- Only as an MSYS2 package (`joe`, built against `msys-2.0.dll`): <https://packages.msys2.org/packages/joe>. Packages are `.pkg.tar.zst` from `https://repo.msys2.org/msys/x86_64/` and need `msys-2.0.dll`, `msys-ncursesw6.dll` and terminfo.
- Expected blockers: the MSYS2 runtime's fork emulation and console handling may not work on nanoserver at all. Treat this as an experiment: if `joe --help` loads, go on. If not, record the error and stop.

### Not worth trying

- **kakoune:** needs POSIX (`fork`, Unix sockets for the client and server). It runs under WSL, Cygwin or MSYS only, with no native Windows build. <https://github.com/mawww/kakoune>
- **amp:** uses `termion`, which does not support Windows. Releases have no Windows binary. <https://github.com/jmacdonald/amp>
- **kilo:** written against `termios`. kibi is the Windows-capable port.
- **mg**, **ne**, **jed:** no maintained native 64-bit Windows build. MSYS2 has none of them (`packages.msys2.org` returns 404 for `mg`, `ne`, `jed` and their `mingw-w64-ucrt-x86_64-*` names).

## Image layout

- Folder: `nano-server-editors/`
- Image: `windows-nano-editors:<WINDOWS_VERSION>` (local only at first; push only when the user asks)
- Dockerfile convention: `ARG WINDOWS_VERSION=2022`, `ARG BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64`, `FROM ${BASE_IMAGE}`. Every version pinned in `ENV`.
- One `RUN` per editor, installed under `C:\Program Files\<editor>`, so a broken editor is easy to drop. One `setx PATH` at the end, with the `reg add HKCU\Environment` workaround for ltsc2019.
- `C:\tests\editors\run-tests.cmd`: the non-interactive smoke tests, with TAP output.
- Phase 2 adds `C:\tests\editors\ptyrun.exe` and its scripts.

## Interactive smoke test with a pseudo console

`--version` only proves the binary loads. To check that an editor really works in nanoserver's console, phase 2 adds `ptyrun.exe`: a small C program, cross-compiled with MinGW-w64 on `ubuntu-latest` (shared with `plans/win32-api-test-framework.md`, whose `kernel32!CreatePseudoConsole` probe tells us whether this can work at all on each Windows version).

```text
ptyrun.exe --cols 80 --rows 25 --timeout-ms 15000 --keys <script> --expect-file <path> <regex> -- <command line>
```

- It creates a pseudo console (`CreatePseudoConsole`) and starts the editor in it.
- It writes the keystrokes from `<script>` into the input pipe. The script holds literal text plus escapes such as `\x13` for Ctrl+S, `\x11` for Ctrl+Q, `\x18` for Ctrl+X and `\e` for Escape, with `{wait 500}` delays.
- It drains the output pipe, so the editor never blocks on writes, and saves the output to a log.
- It succeeds when the editor exits within the timeout **and** `<path>` matches `<regex>`.

Keystroke scripts (type `hello`, save to `C:\tmp\<editor>.txt`, quit):

| Editor | Command line | Keys |
| --- | --- | --- |
| Edit | `edit C:\tmp\edit.txt` | `hello` `\x13` `\x11` |
| nano | `nano C:\tmp\nano.txt` | `hello` `\x0f` `\r` `\x18` |
| Helix | `hx C:\tmp\hx.txt` | `ihello` `\e` `:wq\r` |
| ox | `ox C:\tmp\ox.txt` | `hello` `\x13` `\x11` |
| kibi | `kibi C:\tmp\kibi.txt` | `hello` `\x13` `\x11` |
| Emacs | `emacs -nw -Q C:\tmp\emacs.txt` | `hello` `\x18\x13` `\x18\x03` |
| Textadept | `textadept-curses -n C:\tmp\ta.txt` | `hello` `\x13` `\x11` |

If `CreatePseudoConsole` does not work in nanoserver, the fallback is a manual test: `docker run -it --rm windows-nano-editors:2022`, open each editor, type, save and quit. The results go in the README. CI then runs only the `--version` tests.

## CI

`.github/workflows/editors-container.yml`, following the Rust container workflow:

- Triggers: `push` and `pull_request` to `main` on `nano-server-editors/**` and on the workflow file, plus `workflow_dispatch`.
- `build-ptyrun` job on `ubuntu-latest` (phase 2): MinGW build, upload `ptyrun.exe` as an artifact.
- `build-and-test` job on `[self-hosted, windows, docker]`, `fail-fast: false`, matrix `windows-version: ['2019', '2022', '2025']`, `shell: pwsh`, and the same fork guard as the Rust workflow (`github.event.pull_request.head.repo.full_name == github.repository`):
  1. `docker build --build-arg WINDOWS_VERSION=${{ matrix.windows-version }} -t windows-nano-editors:${{ matrix.windows-version }}-${{ github.sha }} .`
  2. `docker run --name <ctr> <image> "C:\tests\editors\run-tests.cmd > C:\tests\results.tap & type C:\tests\results.tap"`
  3. `docker cp <ctr>:C:\tests\results.tap .`, upload it as an artifact, then `docker rm` and `docker rmi` in an `always()` step
- No bind mounts. Everything the tests need is baked into the image, because the runner is a container that talks to the host daemon over the named pipe.

## Risks

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Silent zero-byte extraction from `tar` (seen with the nano zip on the host) | An editor that "is installed" but cannot start | Check the `MZ` header or SHA-256 after every extraction; use 7-Zip or `Expand-Archive` for zips that `tar` gets wrong |
| VC++ runtime not in nanoserver | Helix and Textadept fail to load | Python embeddable zip for `vcruntime140*.dll`; host copy for `msvcp140.dll`; prefer gnu builds (kibi) |
| No pseudo console in nanoserver | Only `--version` testing in CI | The API test framework checks `CreatePseudoConsole` first; manual test fallback |
| Editors write config into the profile on first start | Failures as `ContainerUser` | Tests run as the default user, and the README notes where each editor keeps its config |
| Large downloads (Emacs, Helix) | Slow builds, big image | One editor per layer; record the image size per editor in the README; drop editors that are not used |
| Abandoned ports (nano 7.2 from 2023) | No security fixes | Note the age in the README; look for a newer build each time the `windows-deps-updater` agent runs |

## Phased task checklist

### Phase 1: P1 editors, version tests

- [ ] Create `nano-server-editors/` (Dockerfile, `build.cmd`, README, `tests/run-tests.cmd`) with Edit, nano and Helix, including the `vcruntime140.dll` step for Helix.
- [ ] Extraction checks (`MZ` header) after each unzip.
- [ ] Acceptance: `build.cmd` on ltsc2022 builds. `run-tests.cmd` passes `edit --version`, `nano --version`, `hx --version` and `hx --health`. A manual `docker run -it` session opens and saves a file in each of the three, and the README records the result.

### Phase 2: pseudo console tests and CI

- [ ] `ptyrun.exe`: source, MinGW build job, and the keystroke scripts above.
- [ ] `.github/workflows/editors-container.yml` with the 2019, 2022 and 2025 matrix.
- [ ] Acceptance: the workflow is green on all three versions. For each P1 editor, the pseudo console test writes `hello` to its file, or the README records why `CreatePseudoConsole` cannot be used on that version.

### Phase 3: P2 and P3 editors

- [ ] Add ox, kibi (gnu build), Emacs (batch tests first), Textadept (local builds only until `msvcp140.dll` has a CI source) and Turbo (MinGW build job).
- [ ] Acceptance: each editor either passes its tests on all three versions, or is removed from the Dockerfile and listed in the README with the error it gave.

### Phase 4: experiments

- [ ] joe from MSYS2: record whether the msys runtime loads on nanoserver at all.
- [ ] Acceptance: a README section with the result, whatever it is.

## Sources

- Microsoft Edit: <https://github.com/microsoft/edit/releases>
- nano for Windows: <https://github.com/okibcn/nano-for-windows/releases>
- Helix: <https://github.com/helix-editor/helix/releases> and <https://docs.helix-editor.com/install.html>
- ox: <https://github.com/curlpipe/ox/releases>
- kibi: <https://github.com/ilai-deutel/kibi/releases>
- GNU Emacs for Windows: <https://ftp.gnu.org/gnu/emacs/windows/>
- Textadept: <https://github.com/orbitalquark/textadept/releases>
- Turbo and Turbo Vision: <https://github.com/magiblot/turbo> and <https://github.com/magiblot/tvision>
- MSYS2 packages: <https://packages.msys2.org/>
- Python embeddable package (VC++ runtime DLLs): <https://docs.python.org/3/using/windows.html#the-embeddable-package>
- Pseudo console API: <https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session>
- kakoune: <https://github.com/mawww/kakoune>
- amp: <https://github.com/jmacdonald/amp>
