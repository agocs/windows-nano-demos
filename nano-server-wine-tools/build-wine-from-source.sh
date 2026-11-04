#!/usr/bin/env bash
# Build the Wine x86_64 PE programs listed in tools.txt from the wine-11.0 source tarball
# (option C in plans/wine-binaries.md). Runs on ubuntu-24.04 in CI.
# Needs: gcc gcc-mingw-w64-x86-64 make flex bison perl curl xz-utils
# Usage: build-wine-from-source.sh [out-dir]   (default: ./out-src)
# Writes the PE files to out-dir, plus configure.txt (the exact configure line) and build.log.
set -euo pipefail

WINE_SRC_URL="https://dl.winehq.org/wine/source/11.0/wine-11.0.tar.xz"
WINE_SRC_SHA256="c07a6857933c1fc60dff5448d79f39c92481c1e9db5aa628db9d0358446e0701"

here="$(cd "$(dirname "$0")" && pwd)"
out="$(mkdir -p "${1:-out-src}" && cd "${1:-out-src}" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 5 --retry-delay 5 -o "$work/wine.tar.xz" "$WINE_SRC_URL"
echo "$WINE_SRC_SHA256  $work/wine.tar.xz" | sha256sum -c -
tar -xf "$work/wine.tar.xz" -C "$work"
cd "$work/wine-11.0"

# Only the PE side is needed. Everything Unix-side that configure would otherwise look for is switched off.
configure_args=(
  --enable-archs=x86_64
  --without-x --without-freetype --without-wayland --without-alsa --without-pulse
  --without-gstreamer --without-vulkan --without-opengl --without-cups --without-dbus
  --without-gnutls --without-sane --without-usb --without-v4l2 --without-pcap --without-krb5
  --without-gssapi --without-netapi --without-sdl --without-udev --without-capi --without-fontconfig
  --without-inotify --without-osmesa --without-oss --without-gphoto --without-pcsclite --without-opencl
  --without-ffmpeg --without-unwind
)
printf './configure %s\n' "${configure_args[*]}" > "$out/configure.txt"
x86_64-w64-mingw32-gcc --version | head -1 >> "$out/configure.txt"

targets=()
while IFS= read -r f || [ -n "$f" ]; do
  f="${f%$'\r'}"
  [ -z "$f" ] && continue
  case "$f" in \#*) continue ;; esac
  targets+=("programs/${f%.*}/x86_64-windows/$f")
done < "$here/tools.txt"

log="$out/build.log"
fail() { tail -100 "$log"; exit 1; }
echo "+ ./configure ${configure_args[*]}" > "$log"
./configure "${configure_args[@]}" >> "$log" 2>&1 || fail
echo "+ make ${targets[*]}" >> "$log"
make -j"$(nproc)" "${targets[@]}" >> "$log" 2>&1 || fail

for t in "${targets[@]}"; do cp "$t" "$out/"; done
ls -l "$out"
