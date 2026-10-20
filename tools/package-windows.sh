#!/bin/sh
# nanoterm for Windows: a release build for x86_64 and arm64, each in
# zig-out/package/nanoterm-windows-<arch>.zip with its license and notices.
# The shell is PowerShell (7 if installed, else Windows PowerShell) on a
# pseudo console, so it needs Windows 10 1809 or later.
#
#     VERSION=0.1.25 sh tools/package-windows.sh
set -eu
cd "$(dirname "$0")/.."
version="${VERSION:?set VERSION}"
fork=""
[ -f ../../src/nanoui.zig ] && fork="--fork=../.."
out=zig-out/package
mkdir -p "$out"
for arch in x86_64 aarch64; do
  prefix="zig-out/windows-$arch"
  zig build -Doptimize=ReleaseFast -Dtarget="$arch-windows-gnu" -Dversion="$version" --prefix "$prefix" $fork
  dir="$out/nanoterm-$version-windows-$arch"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$prefix/bin/nanoterm.exe" "$dir/nanoterm.exe"
  cp LICENSE THIRD_PARTY_NOTICES.md "$dir/"
  name="nanoterm-windows-$arch.zip"
  rm -f "$out/$name"
  (cd "$out" && zip -qr "$name" "nanoterm-$version-windows-$arch")
  rm -rf "$dir"
  (cd "$out" && shasum -a 256 "$name" > "$name.sha256")
  echo "$out/$name"
done
sh tools/manifest.sh "$version"
