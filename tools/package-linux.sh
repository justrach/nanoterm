#!/bin/sh
# nanoterm for Linux: a release build without debug information, for x86_64 and arm64, each in
# zig-out/package/nanoterm-linux-<arch>.tar.gz with its license, notices and a
# .desktop entry. nanoui loads GTK 3 at run time, so it needs only libgtk-3.
#
#     VERSION=0.1.17 sh tools/package-linux.sh
set -eu
cd "$(dirname "$0")/.."
version="${VERSION:?set VERSION}"
fork=""
[ -f ../../src/nanoui.zig ] && fork="--fork=../.."
out=zig-out/package
mkdir -p "$out"
for arch in x86_64 aarch64; do
  prefix="zig-out/linux-$arch"
  zig build -Doptimize=ReleaseFast -Dstrip=true -Dtarget="$arch-linux-gnu" --prefix "$prefix" $fork
  dir="$out/nanoterm-$version-linux-$arch"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp "$prefix/bin/nanoterm" "$dir/nanoterm"
  chmod +x "$dir/nanoterm"
  cp LICENSE THIRD_PARTY_NOTICES.md "$dir/"
  cat > "$dir/nanoterm.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=nanoterm
Comment=Commands and coding agents in one terminal
Exec=nanoterm
Terminal=false
Categories=System;TerminalEmulator;
DESKTOP
  name="nanoterm-linux-$arch.tar.gz"
  tar -C "$out" -czf "$out/$name" "nanoterm-$version-linux-$arch"
  rm -rf "$dir"
  (cd "$out" && shasum -a 256 "$name" > "$name.sha256")
  echo "$out/$name"
done
