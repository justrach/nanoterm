#!/bin/sh
# The terminal benchmark (bench/README.md): nanoterm's, Ghostty's and
# Alacritty's terminal engines reading the same workloads.
#
#   sh bench/run.sh [ITERS]        from apps/nanoterm (or the nanoterm repo)
#
# Clones Ghostty and builds the three runners on first use (bench/.cache),
# generates the workloads, runs each engine ITERS times (7 by default) and
# writes bench/results/<date>/: results.jsonl, the screens, report.md.
set -eu
cd "$(dirname "$0")/.."
iters="${1:-7}"
ghostty_version=v1.3.1
cache=bench/.cache
out="bench/results/$(date +%Y-%m-%d)"
mkdir -p "$cache" "$out"

# nanoterm's runner and the workloads/report tool. A checkout inside nanoui
# builds against it; on its own, against the nanoui it pins.
fork=""
[ -f ../../src/nanoui.zig ] && fork="--fork=../.."
zig build bench -Doptimize=ReleaseFast $fork

# Ghostty's engine, with the Zig it needs (0.15.2: ZIG_015, or zigup's).
if [ ! -d "$cache/ghostty" ]; then
  git clone -q --depth 1 --branch "$ghostty_version" https://github.com/ghostty-org/ghostty.git "$cache/ghostty"
fi
zig015="${ZIG_015:-$HOME/.local/share/zigup/0.15.2/files/zig}"
# macOS 27's SDK lists only arm64e, which Zig 0.15 can't link for arm64:
# answer its SDK lookup with an older SDK that lists arm64, when one is here.
sdkbin=""
old_sdk=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX13*.sdk 2>/dev/null | head -1 || true)
if [ -n "$old_sdk" ]; then
  sdkbin="$cache/xcrun-bin"
  mkdir -p "$sdkbin"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "--show-sdk-path" ] && { echo %s; exit 0; }; done\nexec /usr/bin/xcrun "$@"\n' "$old_sdk" > "$sdkbin/xcrun"
  chmod +x "$sdkbin/xcrun"
fi
(cd bench/ghostty && PATH="${sdkbin:+$PWD/../../$sdkbin:}$PATH" "$zig015" build -Doptimize=ReleaseFast)

# Alacritty's engine.
(cd bench/alacritty && CARGO_TARGET_DIR="$PWD/../.cache/alacritty-target" cargo build --release -q)

zig-out/bin/termbench gen "$cache/workloads"
: > "$out/results.jsonl"
for w in ascii sgr unicode longlines fullscreen; do
  zig-out/bin/nanoterm-bench "$cache/workloads/$w.vt" --iters "$iters" --screen "$out/screen-nanoterm-$w.txt" >> "$out/results.jsonl"
  bench/ghostty/zig-out/bin/ghostty-bench "$cache/workloads/$w.vt" --iters "$iters" --screen "$out/screen-ghostty-$w.txt" >> "$out/results.jsonl"
  "$cache/alacritty-target/release/alacritty-bench" "$cache/workloads/$w.vt" --iters "$iters" --screen "$out/screen-alacritty-$w.txt" >> "$out/results.jsonl"
done

{
  echo "# Terminal engines, $(date +%Y-%m-%d)"
  echo
  echo "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), $(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null); nanoterm $(git rev-parse --short HEAD), Ghostty $ghostty_version, alacritty_terminal 0.26.0; $iters runs each, 16 MiB per workload."
  echo
  zig-out/bin/termbench report "$out/results.jsonl"
} > "$out/report.md"
cat "$out/report.md"
