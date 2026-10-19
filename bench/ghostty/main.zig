//! Ghostty's terminal engine (libghostty-vt: its Terminal and the stream
//! that applies every sequence changing its state) reading a workload as
//! from the pseudo-terminal, in 64 KiB reads, on a 120 x 40 terminal with
//! the app's default scrollback (10 MB). Prints one line of results.jsonl.
//!
//!   ghostty-bench WORKLOAD.vt [--iters N] [--screen OUT.txt]
const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

const chunk = 64 << 10;

/// Quiet, as in the app: the engine's info logs (page resizes) cost time.
pub const std_options: std.Options = .{ .log_level = .err };

pub fn main() !void {
    const alloc = std.heap.smp_allocator;
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len < 2) return error.Usage;
    var iters: usize = 5;
    var screen_path: ?[]const u8 = null;
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--iters")) iters = try std.fmt.parseInt(usize, args[i + 1], 10);
        if (std.mem.eql(u8, args[i], "--screen")) screen_path = args[i + 1];
    }
    const data = try std.fs.cwd().readFileAlloc(alloc, args[1], 1 << 30);
    defer alloc.free(data);
    const ns = try alloc.alloc(u64, iters);
    defer alloc.free(ns);
    for (ns, 0..) |*t, n| {
        var term: ghostty_vt.Terminal = try .init(alloc, .{ .cols = 120, .rows = 40, .max_scrollback = 10_000_000 });
        var stream = term.vtStream();
        var timer = try std.time.Timer.start();
        var at: usize = 0;
        while (at < data.len) : (at += chunk) try stream.nextSlice(data[at..@min(data.len, at + chunk)]);
        t.* = timer.read();
        if (n == iters - 1) if (screen_path) |p| {
            const s = try term.plainString(alloc);
            defer alloc.free(s);
            try std.fs.cwd().writeFile(.{ .sub_path = p, .data = s });
        };
        stream.deinit();
        term.deinit(alloc);
    }
    const rss: u64 = @intCast(std.posix.getrusage(std.posix.rusage.SELF).maxrss);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const name = std.fs.path.stem(args[1]);
    try out.print(alloc, "{{\"engine\":\"ghostty\",\"workload\":\"{s}\",\"bytes\":{d},\"rss_bytes\":{d},\"ns\":[", .{ name, data.len, rss });
    for (ns, 0..) |t, n| try out.print(alloc, "{s}{d}", .{ if (n > 0) "," else "", t });
    try out.appendSlice(alloc, "]}\n");
    try std.fs.File.stdout().writeAll(out.items);
}
