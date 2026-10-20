#!/bin/sh
# The update feed: zig-out/package/manifest.json names the version and the
# sha256 of each platform's archive there (the macOS zip, the Linux
# tarballs, the Windows zips). The packaging scripts run it after each;
# the release carries the last one.
#
#     sh tools/manifest.sh 0.1.26
set -eu
cd "$(dirname "$0")/.."
version="${1:?the version}"
out=zig-out/package
files=""
for f in "$out"/nanoterm-macos-arm64.zip "$out"/nanoterm-linux-*.tar.gz "$out"/nanoterm-windows-*.zip; do
  [ -f "$f" ] || continue
  sum=$(shasum -a 256 "$f" | cut -d' ' -f1)
  entry=$(printf '"%s":{"sha256":"%s"}' "$(basename "$f")" "$sum")
  files="${files:+$files,}$entry"
done
printf '{"version":"%s","files":{%s}}\n' "$version" "$files" > "$out/manifest.json"
