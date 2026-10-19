# Terminal engines: nanoterm, Ghostty, Alacritty

An eval of the part of a terminal that reads what programs print: the
**engine** that parses escape sequences and keeps what the screen holds. It
feeds the same bytes to three engines and measures how fast each reads them,
how much memory it takes, and whether all three end with the same screen.

```sh
sh bench/run.sh        # 7 runs each; bench/results/<date>/report.md
```

`run.sh` clones Ghostty (pinned), builds the three runners, generates the
workloads and writes the report. It needs Zig 0.17 (nanoterm), Zig 0.15.2
(Ghostty; `ZIG_015=…` or zigup's) and cargo (Alacritty).

## What runs

| engine | what is measured | built |
|---|---|---|
| nanoterm | `src/vt.zig`: a command's output as lines and styles; a full-screen program's screen (`screen_vt.zig`, `screen.zig`) | Zig 0.17, ReleaseFast |
| Ghostty 1.3.1 | libghostty-vt: its `Terminal` and `vtStream()`, the stream that applies every sequence changing terminal state | Zig 0.15.2, ReleaseFast (SIMD on) |
| Alacritty | `alacritty_terminal` 0.26.0: its `Term` driven by the vte parser | cargo release, LTO |

Each runner reads the workload into memory, then for each run starts a fresh
terminal (120 × 40, the app's default scrollback: Ghostty 10 MB,
Alacritty 10,000 lines, nanoterm 20,000 lines) and feeds it in 64 KiB reads,
as from a pseudo-terminal. Only feeding is timed. Each prints one JSON line
(`bench/termbench.zig` reads them).

Ghostty's own `terminal-stream` benchmark uses a simplified handler that
"only handles specific terminal operations like printing characters", so the
runner uses the full read-only stream instead, which is the Ghostty engine
replay tools use.

## Workloads

16 MiB each, from a fixed seed (`termbench gen`), so every run and every
machine reads the same bytes:

| workload | what |
|---|---|
| ascii | log lines, 20 to 100 characters |
| sgr | the same with colors (16, 256, truecolor) and bold, as compilers, `ls` and test runners print |
| unicode | CJK, emoji, combining accents, box drawing |
| longlines | lines of 400 to 2000 characters, each wrapped many times |
| fullscreen | a full-screen program on the alternate screen: cursor moves, colored rows, erases, a scrolling region |

## Reading the results

- **The engines do different work on streamed output.** Ghostty and
  Alacritty keep every line in a grid of cells as it arrives, with scrollback
  pages. nanoterm keeps a command's output as lines of text with styles,
  because that is what its blocks show. It works out wrapping and widths when
  drawing, not when reading. Most of nanoterm's lead on ascii, sgr, unicode and
  longlines comes from that design, not from a faster grid.
- **fullscreen is the like-for-like test.** All three keep a grid of cells
  there (nanoterm's `screen.zig` for a program on the alternate screen).
- **The final screens are compared.** For ascii, sgr and fullscreen the
  report says whether each engine ended with the screen the others did,
  trailing spaces and blank rows aside. All three agreeing means each read
  the stream correctly, so the timings compare engines doing the same job.
- **Engines only.** No rendering, fonts, GPU, pseudo-terminal or input latency.
  None of the apps runs, and no window opens. A terminal's speed on screen
  depends on those too.
- **Memory** is the runner's peak resident memory, the 16 MiB workload in
  memory included. nanoterm's longlines figure is higher because it keeps all
  of a command's lines (up to 20,000) with their text.

## What it found

The first runs found two nanoterm problems, both fixed:

| | before | after |
|---|---:|---:|
| ascii (output past 20,000 lines dropped its oldest line one at a time, moving the rest each time: quadratic) | 4 MB/s | 940 MB/s |
| fullscreen (scrolling moved every cell of the region; now the rows' order turns) | 72 MB/s | 161 MB/s |
| fullscreen (runs of printable ASCII written a row at a time, tested against one at a time) | 161 MB/s | 319 MB/s |

Results are in `results/`; run it again after changing the engine, and keep
changes that climb without the screens disagreeing.
