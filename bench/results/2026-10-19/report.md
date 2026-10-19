# Terminal engines, 2026-10-19

Apple M3 Ultra, macOS 27.0; nanoterm 26e1ba2, Ghostty v1.3.1, alacritty_terminal 0.26.0; 7 runs each, 16 MiB per workload.

| workload | engine | MB/s (median) | best | peak memory* |
|---|---|---:|---:|---:|
| ascii | nanoterm | 979 | 1020 | 34.9 MB |
| ascii | ghostty | 151 | 152 | 34.3 MB |
| ascii | alacritty | 181 | 195 | 50.6 MB |
| sgr | nanoterm | 281 | 288 | 41.1 MB |
| sgr | ghostty | 67 | 69 | 34.3 MB |
| sgr | alacritty | 159 | 164 | 50.2 MB |
| unicode | nanoterm | 1039 | 1086 | 34.0 MB |
| unicode | ghostty | 70 | 72 | 34.3 MB |
| unicode | alacritty | 110 | 113 | 52.3 MB |
| longlines | nanoterm | 1848 | 1964 | 88.6 MB |
| longlines | ghostty | 158 | 158 | 34.3 MB |
| longlines | alacritty | 210 | 212 | 50.2 MB |
| fullscreen | nanoterm | 315 | 319 | 25.2 MB |
| fullscreen | ghostty | 100 | 101 | 34.3 MB |
| fullscreen | alacritty | 209 | 209 | 18.5 MB |

\* The runner's peak resident memory, the 16 MiB workload included.

| workload | final screen |
|---|---|
| ascii | nanoterm: agrees; ghostty: agrees; alacritty: agrees;
| sgr | nanoterm: agrees; ghostty: agrees; alacritty: agrees;
| fullscreen | nanoterm: agrees; ghostty: agrees; alacritty: agrees;
