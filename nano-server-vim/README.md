# Vim windows nano server container

A Windows Nano Server container with the console version of [Vim](https://www.vim.org/) (`vim.exe`) and [MinGit](https://github.com/git-for-windows/git/wiki/MinGit) on the path. Git is included so that Vim plugin managers can clone plugins.

Versions are pinned in the `ENV` block of the `Dockerfile`:

- Vim from the [vim-win32-installer](https://github.com/vim/vim-win32-installer/releases) x64 zip
- MinGit (non-busybox, 64-bit) from [Git for Windows](https://github.com/git-for-windows/git/releases), installed to `C:\Program Files\MinGit`

Despite the folder name, this image is based on Windows Server Core (`servercore`), not Nano Server. `vim64.dll` imports `kernel32!DebugBreakProcess`, plus a few `gdi32` and `winmm` functions, and the Nano Server ltsc2019, ltsc2022 and ltsc2025 images do not export them. Vim fails to start there with `STATUS_ENTRYPOINT_NOT_FOUND` (0xC0000139), and `kernel32.dll` can't be replaced inside a container. You can still pass `BASE_IMAGE` to try a different base.

The bundled `libsodium.dll` (used for `:X` encryption) needs `vcruntime140.dll`. Server Core doesn't ship it, so the `Dockerfile` takes it from the official Python embeddable zip in a build stage. Nothing is copied from the host.

## Building

To build a 2022 container:

```cmd
build.cmd
```

To build the windows 2019 container:

From powershell

```pwsh
$env:WINDOWS_VERSION=2019
./build.cmd
```

The Command Prompt

```cmd
set WINDOWS_VERSION=2019
build.cmd
```

## Running

Start an interactive session:

```cmd
docker run -it --rm windows-nano-vim:2022 vim
```

Run Vim non-interactively. Pass each argument separately: if you pass one string with embedded double quotes, docker escapes them as `\"`, which `cmd.exe` does not understand.

```cmd
docker run --rm windows-nano-vim:2022 vim -Nu NONE -Es -c "put ='hello'" -c "wq C:\t.txt" "&&" type C:\t.txt
```
