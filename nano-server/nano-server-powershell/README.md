# PowerShell 7 windows nano server development container

A Windows nano server container for writing and testing PowerShell. `pwsh` is the default command.

It contains:

- PowerShell 7.6.9
- MinGit 2.56.0.4 (in `C:\Program Files\MinGit`, with `cmd` on the path)
- The micro text editor 2.0.15
- These modules from the PowerShell Gallery, installed for all users in `C:\Program Files\PowerShell\Modules`:
  - Pester 6.2.0
  - PSScriptAnalyzer 1.25.0
  - Microsoft.PowerShell.PlatyPS 1.0.3
  - PSReadLine 2.4.5
  - Microsoft.PowerShell.PSResourceGet 1.2.0

All versions are pinned in the `ENV` block at the top of the `Dockerfile`.

## Running

```cmd
docker run -it --rm windows-nano-powershell:2022
```

Run a single command:

```cmd
docker run --rm windows-nano-powershell:2022 pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse"
```

## Building

To build a 2025 container, the default:

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

`WINDOWS_VERSION` can be 2019, 2022 or 2025. To build on a different base image, set `BASE_IMAGE` as well, for example:

```cmd
set BASE_IMAGE=mcr.microsoft.com/windows/nanoserver:ltsc2025-amd64
build.cmd
```

## Testing

`tests/smoke.ps1` checks `$PSVersionTable`, `git`, `micro`, a tiny Pester test, PSScriptAnalyzer and platyPS. The `PowerShell container` GitHub workflow builds the image for 2019, 2022 and 2025 and runs the script with `docker run --rm`.

## Notes

Under Hyper-V isolation `pwsh` crashes with exit code 255 and no output when it runs PSResourceGet or PowerShellGet as `ContainerAdministrator`. It works as `ContainerUser`, so the `Dockerfile` installs the modules as `ContainerUser` and uses `ContainerAdministrator` only for `icacls`.
