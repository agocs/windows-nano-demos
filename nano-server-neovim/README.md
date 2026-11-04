# Neovim windows nano server container

A Windows Nano Server container with [Neovim](https://neovim.io/) and [MinGit](https://github.com/git-for-windows/git/wiki/MinGit) on the path. Git is included so that Neovim plugin managers such as lazy.nvim can clone plugins.

Versions are pinned in the `ENV` block of the `Dockerfile`:

- Neovim from the [neovim releases](https://github.com/neovim/neovim/releases) `nvim-win64.zip`
- MinGit (non-busybox, 64-bit) from [Git for Windows](https://github.com/git-for-windows/git/releases), installed to `C:\Program Files\MinGit`

Despite the folder name, this image is based on Windows Server Core (`servercore`), not Nano Server. `nvim.exe` imports `kernel32!DebugBreakProcess`, and the Nano Server ltsc2019, ltsc2022 and ltsc2025 images do not export it. Neovim fails to start there with `STATUS_ENTRYPOINT_NOT_FOUND` (0xC0000139), and `kernel32.dll` can't be replaced inside a container. You can still pass `BASE_IMAGE` to try a different base.

Neovim needs the Visual C++ runtime (`vcruntime140.dll`). Server Core doesn't ship it, so the `Dockerfile` takes it from the official Python embeddable zip in a build stage. Nothing is copied from the host.

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
docker run -it --rm windows-nano-neovim:2022 nvim
```

Run Neovim headless. Pass each argument separately: if you pass one string with embedded double quotes, docker escapes them as `\"`, which `cmd.exe` does not understand.

```cmd
docker run --rm windows-nano-neovim:2022 nvim --headless -c "lua io.write('ok')" -c q
```
