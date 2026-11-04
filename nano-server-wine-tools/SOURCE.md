# Source for the Wine programs in this image

The programs in `C:\Program Files\wine-tools` are from Wine and are licensed under the GNU Lesser General Public License, version 2.1 or later. See `COPYING.LIB`, `LICENSE` and `AUTHORS` in the same folder.

## Binaries

They are the unmodified x86_64 PE files from WineHQ's Ubuntu 24.04 (noble) package. They are copied out of `opt/wine-stable/lib/wine/x86_64-windows/`, and nothing is patched or rebuilt.

- Package: `wine-stable-amd64`, version `11.0.0.0~noble-1`
- URL: <https://dl.winehq.org/wine-builds/ubuntu/pool/main/w/wine/wine-stable-amd64_11.0.0.0~noble-1_amd64.deb>
- Size: 122,823,532 bytes
- SHA-256: `6cb835e2171b5572b17f1c06729735c2c7e40178239d7fa6c29ef14bd9b40d16`

## Corresponding source

- Wine version: 11.0
- Tarball: <https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz>
- Size: 33,172,240 bytes
- SHA-256: `c07a6857933c1fc60dff5448d79f39c92481c1e9db5aa628db9d0358446e0701`
- Signature: <https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz.sign>
- Git tag: `wine-11.0` (`ce295733f9a67970b7f60d7af201f2ac16441a50`) in <https://gitlab.winehq.org/wine/wine>

Each program's source is in `programs/<name>/` of that tarball.

This repository does not yet host its own copy of the tarball. Until it does, the WineHQ URL above is the only source location. Before the image is pushed to a public registry, mirror the tarball (for example as a GitHub release asset whose name matches the image tag) and add its URL here.

## How the files were extracted

The scripts that pick the files are in <https://github.com/zippy1981/windows-nano-demos> under `nano-server-wine-tools/`: `extract-wine.sh` (CI), `fetch-wine.ps1` (local builds) and `tools.txt` (the list of programs). There are no patches.
