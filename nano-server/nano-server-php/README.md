# Node and PHP development windows nano server development container

Node and PHP actually work. A text editor called [micro](https://github.com/micro-editor/micro) is available.

Vite, Composer and the Laravel installer are installed and in your path.

Available at <https://hub.docker.com/repository/docker/zippy1981/windows-nano-php/general>.

## Versions

| Component | Version |
| --- | --- |
| PHP (NTS x64, vs17) | 8.5.12-1 |
| Node.js (LTS) | 26.13.0 |
| npm | 12.2.1 |
| micro | 2.0.15 |
| Composer | latest at build time |

The PHP build enables the `curl`, `fileinfo`, `openssl` and `zip` extensions. The Visual C++ runtime DLLs PHP needs are installed in a Server Core build stage and copied into the nano server image, so the build doesn't need anything from the host. `where.exe`, which nano server lacks, is copied from the same stage.

## Building

Images are built for Windows Server 2019, 2022 and 2025. `build.cmd` builds 2025 unless `WINDOWS_VERSION` is set:

```cmd
build.cmd
```

To build the Windows 2019 or 2025 container from PowerShell:

```pwsh
$env:WINDOWS_VERSION=2019
./build.cmd
```

From the Command Prompt:

```cmd
set WINDOWS_VERSION=2019
build.cmd
```

The Dockerfile takes two build arguments, and `build.cmd` passes both through when they're set:

- `WINDOWS_VERSION`: `2019`, `2022` or `2025` (default). It picks the nano server base and the Server Core image that supplies the Visual C++ runtime.
- `BASE_IMAGE`: the nano server base image. It defaults to `mcr.microsoft.com/windows/nanoserver:ltsc${WINDOWS_VERSION}-amd64`.

The Server Core build stage is only used during the build, but the first build for each Windows version downloads that Server Core image.
