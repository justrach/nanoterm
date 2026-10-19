//! nanoterm's terminal engine (src/vt.zig: a command's output as lines and
//! styles; a full-screen program's screen, screen_vt.zig) reading a workload
//! as it comes from the pseudo-terminal, in 64 KiB reads, on a 120 x 40
//! terminal. Prints one line of results.jsonl (bench/README.md).
//!
//!   nanoterm-bench WORKLOAD.vt [--iters N] [--screen OUT.txt]
const std = @import("std");
const vt = @import("vt");

const chunk = 64 << 10;

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// The visible screen: a full-screen program's, else the last rows of output.
fn dumpScreen(gpa: std.mem.Allocator, io: std.Io, o: *const vt.Output, path: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    if (o.full) |f| {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const starts = try arena.allocator().alloc(u32, f.screen.cols + 1);
        for (0..f.screen.rows) |y| {
            try out.appendSlice(gpa, f.screen.rowText(arena.allocator(), y, starts));
            try out.append(gpa, '\n');
        }
    } else {
        const lines = o.lines.items;
        const first = lines.len -| o.rows;
        for (lines[first..]) |l| {
            try out.appendSlice(gpa, l.text.items);
            try out.append(gpa, '\n');
        }
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.Usage;
    var iters: usize = 5;
    var screen_path: ?[]const u8 = null;
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--iters")) iters = try std.fmt.parseInt(usize, args[i + 1], 10);
        if (std.mem.eql(u8, args[i], "--screen")) screen_path = args[i + 1];
    }
    const data = try std.Io.Dir.cwd().readFileAlloc(io, args[1], gpa, .limited(1 << 30));
    defer gpa.free(data);
    const ns = try gpa.alloc(u64, iters);
    defer gpa.free(ns);
    for (ns, 0..) |*t, n| {
        var o: vt.Output = .init(gpa);
        o.cols = 120;
        o.rows = 40;
        const t0 = now();
        var at: usize = 0;
        while (at < data.len) : (at += chunk) try o.feed(data[at..@min(data.len, at + chunk)]);
        t.* = now() - t0;
        if (n == iters - 1) if (screen_path) |p| try dumpScreen(gpa, io, &o, p);
        o.deinit();
    }
    const ru = std.posix.getrusage(0);
    const rss: u64 = @intCast(ru.maxrss); // bytes on macOS
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const name = std.fs.path.stem(args[1]);
    try out.print(gpa, "{{\"engine\":\"nanoterm\",\"workload\":\"{s}\",\"bytes\":{d},\"rss_bytes\":{d},\"ns\":[", .{ name, data.len, rss });
    for (ns, 0..) |t, n| try out.print(gpa, "{s}{d}", .{ if (n > 0) "," else "", t });
    try out.appendSlice(gpa, "]}\n");
    try std.Io.File.stdout().writeStreamingAll(io, out.items);
}
