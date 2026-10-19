//! Alacritty's terminal engine (alacritty_terminal: its Term and the vte
//! parser that drives it) reading a workload as from the pseudo-terminal, in
//! 64 KiB reads, on a 120 x 40 terminal with the app's default scrollback
//! (10,000 lines). Prints one line of results.jsonl (bench/README.md).
//!
//!   alacritty-bench WORKLOAD.vt [--iters N] [--screen OUT.txt]
use std::time::Instant;

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::index::{Column, Line};
use alacritty_terminal::term::cell::Flags;
use alacritty_terminal::term::test::TermSize;
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::vte::ansi::Processor;

const CHUNK: usize = 64 << 10;

struct Quiet;
impl EventListener for Quiet {
    fn send_event(&self, _event: Event) {}
}

fn screen(term: &Term<Quiet>) -> String {
    let grid = term.grid();
    let mut out = String::new();
    for y in 0..grid.screen_lines() {
        for x in 0..grid.columns() {
            let cell = &grid[Line(y as i32)][Column(x)];
            if cell.flags.contains(Flags::WIDE_CHAR_SPACER) {
                continue;
            }
            out.push(cell.c);
        }
        out.push('\n');
    }
    out
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = args.get(1).expect("usage: alacritty-bench WORKLOAD.vt [--iters N] [--screen OUT]");
    let mut iters = 5usize;
    let mut screen_path: Option<String> = None;
    let mut i = 2;
    while i + 1 < args.len() {
        match args[i].as_str() {
            "--iters" => iters = args[i + 1].parse().unwrap(),
            "--screen" => screen_path = Some(args[i + 1].clone()),
            _ => {}
        }
        i += 2;
    }
    let data = std::fs::read(path).unwrap();
    let mut ns = Vec::with_capacity(iters);
    for n in 0..iters {
        let config = Config { scrolling_history: 10_000, ..Config::default() };
        let mut term = Term::new(config, &TermSize::new(120, 40), Quiet);
        let mut parser: Processor = Processor::new();
        let t0 = Instant::now();
        for chunk in data.chunks(CHUNK) {
            parser.advance(&mut term, chunk);
        }
        ns.push(t0.elapsed().as_nanos() as u64);
        if n == iters - 1 {
            if let Some(p) = &screen_path {
                std::fs::write(p, screen(&term)).unwrap();
            }
        }
    }
    let rss = unsafe {
        let mut ru: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut ru);
        ru.ru_maxrss as u64 // bytes on macOS
    };
    let name = std::path::Path::new(path).file_stem().unwrap().to_string_lossy();
    let list: Vec<String> = ns.iter().map(|t| t.to_string()).collect();
    println!(
        "{{\"engine\":\"alacritty\",\"workload\":\"{}\",\"bytes\":{},\"rss_bytes\":{},\"ns\":[{}]}}",
        name,
        data.len(),
        rss,
        list.join(",")
    );
}
