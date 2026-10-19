//! The terminal benchmark's workloads and report (bench/README.md).
//!
//!   termbench gen DIR            the workloads, the same bytes every time
//!   termbench report RESULTS     results.jsonl (one line per engine and
//!                                workload, from the runners) as Markdown,
//!                                and whether the engines' screens agree
//!
//! Each workload is what a terminal reads from a program, as it comes:
//!   ascii       log lines, 20-100 characters
//!   sgr         the same with colors (16, 256, truecolor) and bold, as
//!               compilers, ls and test runners print
//!   unicode     CJK, emoji, accents (combining marks), box drawing
//!   longlines   lines of 400-2000 characters, wrapped many times
//!   fullscreen  a full-screen program on the alternate screen: cursor
//!               moves, colored rows, erases, scrolling regions
const std = @import("std");

const workload_bytes = 16 << 20;

const words = [_][]const u8{
    "the",     "build",  "passed", "error",   "warning", "src/main.zig", "line",   "42",
    "request", "200",    "GET",    "/api/v1", "user",    "session",      "cache",  "miss",
    "ok",      "test",   "failed", "expected", "found",  "0x7ffd1a2b",   "info",   "debug",
    "->",      "=>",     "{",      "}",       "Compiling", "nanoterm",   "v0.1.15", "done",
};

fn pick(r: std.Random, comptime T: type, items: []const T) T {
    return items[r.uintLessThan(usize, items.len)];
}

fn utf8(out: *std.ArrayList(u8), gpa: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &buf);
    try out.appendSlice(gpa, buf[0..n]);
}

/// Words up to `max` characters, then CR LF.
fn line(out: *std.ArrayList(u8), gpa: std.mem.Allocator, r: std.Random, min: usize, max: usize, colors: bool) !void {
    const want = min + r.uintLessThan(usize, max - min + 1);
    var n: usize = 0;
    while (true) {
        const w = pick(r, []const u8, &words);
        if (n + w.len + 1 > want) break;
        if (n > 0) {
            try out.append(gpa, ' ');
            n += 1;
        }
        const colored = colors and r.uintLessThan(u8, 3) == 0;
        if (colored) switch (r.uintLessThan(u8, 4)) {
            0 => try out.print(gpa, "\x1b[{d}m", .{30 + r.uintLessThan(u8, 8)}),
            1 => try out.print(gpa, "\x1b[38;5;{d}m", .{r.int(u8)}),
            2 => try out.print(gpa, "\x1b[38;2;{d};{d};{d}m", .{ r.int(u8), r.int(u8), r.int(u8) }),
            else => try out.appendSlice(gpa, "\x1b[1m"),
        };
        try out.appendSlice(gpa, w);
        if (colored) try out.appendSlice(gpa, "\x1b[0m");
        n += w.len;
    }
    try out.appendSlice(gpa, "\r\n");
}

fn unicodeLine(out: *std.ArrayList(u8), gpa: std.mem.Allocator, r: std.Random) !void {
    const cells = 30 + r.uintLessThan(usize, 31);
    var n: usize = 0;
    while (n < cells) {
        switch (r.uintLessThan(u8, 6)) {
            0 => {
                try utf8(out, gpa, @intCast(0x4E00 + r.uintLessThan(u21, 0x5000)));
                n += 2;
            },
            1 => {
                try utf8(out, gpa, @intCast(0x1F600 + r.uintLessThan(u21, 0x50)));
                n += 2;
            },
            2 => {
                try out.append(gpa, 'a' + r.uintLessThan(u8, 26));
                try utf8(out, gpa, 0x0301);
                n += 1;
            },
            3 => {
                try utf8(out, gpa, @intCast(0x2500 + r.uintLessThan(u21, 0x80)));
                n += 1;
            },
            else => {
                const w = pick(r, []const u8, &words);
                try out.appendSlice(gpa, w);
                try out.append(gpa, ' ');
                n += w.len + 1;
            },
        }
    }
    try out.appendSlice(gpa, "\r\n");
}

/// A full-screen program's frame on a 120 x 40 screen.
fn frame(out: *std.ArrayList(u8), gpa: std.mem.Allocator, r: std.Random) !void {
    try out.appendSlice(gpa, "\x1b[H");
    for (1..41) |row| {
        try out.print(gpa, "\x1b[{d};1H\x1b[{d};{d}m", .{ row, 30 + r.uintLessThan(u8, 8), 40 + r.uintLessThan(u8, 8) });
        var n: usize = 0;
        while (n < 100) {
            const w = pick(r, []const u8, &words);
            try out.appendSlice(gpa, w);
            try out.append(gpa, ' ');
            n += w.len + 1;
        }
        try out.appendSlice(gpa, "\x1b[0m\x1b[K");
    }
    // A scrolling region scrolled, as a pager or an editor scrolls.
    try out.print(gpa, "\x1b[5;35r\x1b[35;1H", .{});
    for (0..8) |_| {
        try out.appendSlice(gpa, "\n");
        try line(out, gpa, r, 20, 100, true);
    }
    try out.appendSlice(gpa, "\x1b[r\x1b[40;1H\x1b[7m-- status --\x1b[0m\x1b[K");
}

fn generate(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(0x7e57_7e57 ^ std.hash.Wyhash.hash(0, name));
    const r = prng.random();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, workload_bytes + 8192);
    if (std.mem.eql(u8, name, "fullscreen")) try out.appendSlice(gpa, "\x1b[?1049h");
    while (out.items.len < workload_bytes) {
        if (std.mem.eql(u8, name, "ascii")) {
            try line(&out, gpa, r, 20, 100, false);
        } else if (std.mem.eql(u8, name, "sgr")) {
            try line(&out, gpa, r, 20, 100, true);
        } else if (std.mem.eql(u8, name, "unicode")) {
            try unicodeLine(&out, gpa, r);
        } else if (std.mem.eql(u8, name, "longlines")) {
            try line(&out, gpa, r, 400, 2000, false);
        } else {
            try frame(&out, gpa, r);
        }
    }
    return out.toOwnedSlice(gpa);
}

pub const workloads = [_][]const u8{ "ascii", "sgr", "unicode", "longlines", "fullscreen" };

/// One runner's line in results.jsonl.
const Result = struct {
    engine: []const u8,
    workload: []const u8,
    bytes: u64,
    ns: []const u64,
    rss_bytes: u64,
};

fn median(gpa: std.mem.Allocator, ns: []const u64) !u64 {
    const sorted = try gpa.dupe(u64, ns);
    defer gpa.free(sorted);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));
    return sorted[sorted.len / 2];
}

/// The screen a runner left, rows with trailing spaces trimmed.
fn screen(gpa: std.mem.Allocator, io: std.Io, dir: []const u8, engine: []const u8, workload: []const u8) ?[]u8 {
    var buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/screen-{s}-{s}.txt", .{ dir, engine, workload }) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return null;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |row| {
        out.appendSlice(gpa, std.mem.trimEnd(u8, row, " ")) catch {};
        out.append(gpa, '\n') catch {};
    }
    gpa.free(data);
    // Trailing blank rows are left out by some engines' dumps.
    while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
    return out.toOwnedSlice(gpa) catch null;
}

fn report(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
    defer gpa.free(data);
    const dir = std.fs.path.dirname(path) orelse ".";
    var parsed: std.ArrayList(std.json.Parsed(Result)) = .empty;
    defer {
        for (parsed.items) |p| p.deinit();
        parsed.deinit(gpa);
    }
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l| {
        if (std.mem.trim(u8, l, " \r").len == 0) continue;
        try parsed.append(gpa, try std.json.parseFromSlice(Result, gpa, l, .{ .ignore_unknown_fields = true }));
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.appendSlice(gpa, "| workload | engine | MB/s (median) | best | peak memory* |\n|---|---|---:|---:|---:|\n");
    for (workloads) |w| for (parsed.items) |p| {
        const v = p.value;
        if (!std.mem.eql(u8, v.workload, w)) continue;
        const med = try median(gpa, v.ns);
        const best = std.mem.min(u64, v.ns);
        const mb = @as(f64, @floatFromInt(v.bytes)) / (1 << 20);
        try out.print(gpa, "| {s} | {s} | {d:.0} | {d:.0} | {d:.1} MB |\n", .{
            w,                                                         v.engine,
            mb / (@as(f64, @floatFromInt(med)) / 1e9),                 mb / (@as(f64, @floatFromInt(best)) / 1e9),
            @as(f64, @floatFromInt(v.rss_bytes)) / (1 << 20),
        });
    };
    try out.appendSlice(gpa, "\n\\* The runner's peak resident memory, the 16 MiB workload included.\n");
    // Whether each engine ended with the screen the others did.
    try out.appendSlice(gpa, "\n| workload | final screen |\n|---|---|\n");
    for ([_][]const u8{ "ascii", "sgr", "fullscreen" }) |w| {
        const engines = [_][]const u8{ "nanoterm", "ghostty", "alacritty" };
        var screens: [3]?[]u8 = undefined;
        for (engines, 0..) |e, i| screens[i] = screen(gpa, io, dir, e, w);
        defer for (screens) |s| if (s) |x| gpa.free(x);
        try out.print(gpa, "| {s} |", .{w});
        for (engines, 0..) |e, i| {
            const s = screens[i] orelse {
                try out.print(gpa, " {s}: no screen;", .{e});
                continue;
            };
            var agree: usize = 0;
            for (screens, 0..) |o, j| if (j != i) if (o) |x| {
                agree += @intFromBool(std.mem.eql(u8, s, x));
            };
            try out.print(gpa, " {s}: {s};", .{ e, if (agree > 0) "agrees" else "differs" });
        }
        try out.appendSlice(gpa, "\n");
    }
    try std.Io.File.stdout().writeStreamingAll(io, out.items);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 3 and std.mem.eql(u8, args[1], "gen")) {
        try std.Io.Dir.cwd().createDirPath(io, args[2]);
        for (workloads) |w| {
            const data = try generate(gpa, w);
            defer gpa.free(data);
            var buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&buf, "{s}/{s}.vt", .{ args[2], w });
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
        }
        return;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "report")) return report(gpa, io, args[2]);
    std.debug.print("usage: termbench gen DIR | termbench report RESULTS.jsonl\n", .{});
    return error.Usage;
}

test "the workloads are the same every time" {
    const a = try generate(std.testing.allocator, "sgr");
    defer std.testing.allocator.free(a);
    const b = try generate(std.testing.allocator, "sgr");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
    try std.testing.expect(a.len >= workload_bytes);
}
