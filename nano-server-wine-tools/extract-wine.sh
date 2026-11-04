#!/usr/bin/env bash
# Extract the Wine x86_64 PE programs listed in tools.txt from the pinned WineHQ wine-stable .deb.
# Runs on ubuntu-latest in CI (option A in plans/wine-binaries.md). fetch-wine.ps1 is the Windows equivalent.
# Usage: extract-wine.sh [out-dir]   (default: ./out)
set -euo pipefail

WINE_DEB_URL="https://dl.winehq.org/wine-builds/ubuntu/pool/main/w/wine/wine-stable-amd64_11.0.0.0~noble-1_amd64.deb"
WINE_DEB_SHA256="6cb835e2171b5572b17f1c06729735c2c7e40178239d7fa6c29ef14bd9b40d16"

here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-out}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Wine core modules that wrap the Unix side. They must never be copied onto real Windows.
deny=" ntdll win32u kernel32 kernelbase user32 gdi32 advapi32 ws2_32 msvcrt ucrtbase combase ole32 rpcrt4 sechost "

curl -fsSL --retry 5 --retry-delay 5 -o "$work/wine.deb" "$WINE_DEB_URL"
echo "$WINE_DEB_SHA256  $work/wine.deb" | sha256sum -c -
dpkg-deb -x "$work/wine.deb" "$work/root"
PE="$work/root/opt/wine-stable/lib/wine/x86_64-windows"
UNIX="$work/root/opt/wine-stable/lib/wine/x86_64-unix"

mkdir -p "$out"
while IFS= read -r f || [ -n "$f" ]; do
  f="${f%$'\r'}"
  [ -z "$f" ] && continue
  case "$f" in \#*) continue ;; esac
  case "$f" in */* | *\\*) echo "refusing $f: not a plain file name" >&2; exit 1 ;; esac
  base="${f%.*}"
  lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
  case "$deny" in *" $lower "*) echo "refusing $f: Wine core module" >&2; exit 1 ;; esac
  if [ -e "$UNIX/$base.so" ]; then echo "refusing $f: has a unixlib ($base.so)" >&2; exit 1; fi
  if [ ! -f "$PE/$f" ]; then echo "missing $f in the package" >&2; exit 1; fi
  cp "$PE/$f" "$out/"
done < "$here/tools.txt"
ls -l "$out"
