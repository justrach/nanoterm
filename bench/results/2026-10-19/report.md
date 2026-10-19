# Terminal engines, 2026-10-19

Apple M3 Ultra, macOS 27.0; nanoterm 907921f, Ghostty v1.3.1, alacritty_terminal 0.26.0; 7 runs each, 16 MiB per workload.

| workload | engine | MB/s (median) | best | memory after |
|---|---|---:|---:|---:|
| ascii | nanoterm | 940 | 958 | 34.9 MB |
| ascii | ghostty | 149 | 152 | 34.3 MB |
| ascii | alacritty | 196 | 202 | 50.6 MB |
| sgr | nanoterm | 281 | 288 | 41.1 MB |
| sgr | ghostty | 68 | 70 | 34.3 MB |
| sgr | alacritty | 157 | 161 | 50.6 MB |
| unicode | nanoterm | 987 | 1012 | 34.0 MB |
| unicode | ghostty | 69 | 70 | 34.3 MB |
| unicode | alacritty | 107 | 112 | 53.3 MB |
| longlines | nanoterm | 1882 | 1951 | 88.6 MB |
| longlines | ghostty | 154 | 155 | 34.3 MB |
| longlines | alacritty | 211 | 213 | 50.6 MB |
| fullscreen | nanoterm | 319 | 326 | 25.2 MB |
| fullscreen | ghostty | 100 | 101 | 34.3 MB |
| fullscreen | alacritty | 203 | 205 | 18.6 MB |

| workload | screens |
|---|---|
| ascii | nanoterm: agrees; ghostty: agrees; alacritty: agrees;
| sgr | nanoterm: agrees; ghostty: agrees; alacritty: agrees;
| fullscreen | nanoterm: agrees; ghostty: agrees; alacritty: agrees;
