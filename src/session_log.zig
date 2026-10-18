//! The conversations had, kept across launches for the palette (⌘P): each
//! finished turn's prompt, agent, directory, time and the start of its
//! reply, a JSON line each in nanoterm's own file (never the agents'). A
//! turn of this run also remembers where it lives, to jump to it.
const std = @import("std");

/// Entries kept in memory (the newest).
const keep = 2000;
const max_prompt = 2000;
const max_reply = 1200;

pub const Entry = struct {
    /// Unix seconds.
    time: i64,
    cwd: []u8,
    agent: []u8,
    prompt: []u8,
    reply: []u8,
    /// This run's session and turn; compared, never followed, until the
    /// palette finds them still alive.
    session: u64 = 0,
    turn: ?*const anyopaque = null,
};

/// The longest start of `s` within `n` bytes that ends on a character.
fn cut(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var i = n;
    while (i > 0 and s[i] & 0xC0 == 0x80) i -= 1;
    return s[0..i];
}

pub const Log = struct {
    gpa: std.mem.Allocator,
    /// Oldest first.
    entries: std.ArrayList(Entry) = .empty,
    /// The file; null keeps it in memory (tests).
    path: ?[]const u8 = null,
    io: ?std.Io = null,

    pub fn deinit(l: *Log) void {
        for (l.entries.items) |e| l.free(e);
        l.entries.deinit(l.gpa);
    }

    fn free(l: *Log, e: Entry) void {
        l.gpa.free(e.cwd);
        l.gpa.free(e.agent);
        l.gpa.free(e.prompt);
        l.gpa.free(e.reply);
    }

    fn add(l: *Log, e: Entry) !void {
        var owned: Entry = .{
            .time = e.time,
            .cwd = try l.gpa.dupe(u8, e.cwd),
            .agent = undefined,
            .prompt = undefined,
            .reply = undefined,
            .session = e.session,
            .turn = e.turn,
        };
        errdefer l.gpa.free(owned.cwd);
        owned.agent = try l.gpa.dupe(u8, e.agent);
        errdefer l.gpa.free(owned.agent);
        owned.prompt = try l.gpa.dupe(u8, cut(std.mem.trim(u8, e.prompt, " \n"), max_prompt));
        errdefer l.gpa.free(owned.prompt);
        owned.reply = try l.gpa.dupe(u8, cut(std.mem.trim(u8, e.reply, " \n"), max_reply));
        errdefer l.gpa.free(owned.reply);
        try l.entries.append(l.gpa, owned);
        if (l.entries.items.len > keep) l.free(l.entries.orderedRemove(0));
    }

    /// Reads the file's entries (the newest `keep`), and keeps its path.
    pub fn load(l: *Log, io: std.Io, path: []const u8) void {
        l.path = path;
        l.io = io;
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, l.gpa, .limited(16 * 1024 * 1024)) catch return;
        defer l.gpa.free(data);
        var arena: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena.deinit();
        const Line = struct { t: i64, cwd: []const u8 = "", agent: []const u8 = "", prompt: []const u8 = "", reply: []const u8 = "" };
        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        while (lines.next()) |line| {
            _ = arena.reset(.retain_capacity);
            const e = std.json.parseFromSliceLeaky(Line, arena.allocator(), line, .{ .ignore_unknown_fields = true }) catch continue;
            if (e.prompt.len == 0) continue;
            l.add(.{ .time = e.t, .cwd = @constCast(e.cwd), .agent = @constCast(e.agent), .prompt = @constCast(e.prompt), .reply = @constCast(e.reply) }) catch return;
        }
    }

    /// Adds a finished turn, and appends it to the file.
    pub fn record(l: *Log, e: Entry) void {
        if (std.mem.trim(u8, e.prompt, " \n").len == 0) return;
        l.add(e) catch return;
        const path = l.path orelse return;
        const io = l.io orelse return;
        const last = l.entries.items[l.entries.items.len - 1];
        const line = std.json.Stringify.valueAlloc(l.gpa, .{ .t = last.time, .cwd = last.cwd, .agent = last.agent, .prompt = last.prompt, .reply = last.reply }, .{}) catch return;
        defer l.gpa.free(line);
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        var file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return;
        defer file.close(io);
        const end = file.length(io) catch return;
        file.writePositionalAll(io, line, end) catch return;
        file.writePositionalAll(io, "\n", end + line.len) catch {};
    }
};

/// "just now", "5m ago", "3h ago", "yesterday", "4d ago".
pub fn ago(buf: []u8, at: i64, then: i64) []const u8 {
    const d = @max(0, at - then);
    if (d < 60) return "just now";
    if (d < 3600) return std.fmt.bufPrint(buf, "{d}m ago", .{@divTrunc(d, 60)}) catch "";
    if (d < 86400) return std.fmt.bufPrint(buf, "{d}h ago", .{@divTrunc(d, 3600)}) catch "";
    if (d < 2 * 86400) return "yesterday";
    if (d < 30 * 86400) return std.fmt.bufPrint(buf, "{d}d ago", .{@divTrunc(d, 86400)}) catch "";
    // Older: the date.
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, then)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.bufPrint(buf, "{s} {d}, {d}", .{ months[md.month.numeric() - 1], md.day_index + 1, yd.year }) catch "";
}

pub fn now(io: std.Io) i64 {
    const ts = std.Io.Clock.real.now(io);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_s));
}

test "kept across launches, cut to size, the newest last" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/nanoterm-test-log";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    var l: Log = .{ .gpa = gpa };
    defer l.deinit();
    l.load(io, dir ++ "/sub/sessions.jsonl");
    l.record(.{ .time = 100, .cwd = @constCast("/a"), .agent = @constCast("graff"), .prompt = @constCast("why is the build slow?"), .reply = @constCast("Because \"LTO\"\nis on.") });
    l.record(.{ .time = 200, .cwd = @constCast("/b"), .agent = @constCast("Claude Code"), .prompt = @constCast("  "), .reply = @constCast("") });
    var again: Log = .{ .gpa = gpa };
    defer again.deinit();
    again.load(io, dir ++ "/sub/sessions.jsonl");
    try std.testing.expectEqual(@as(usize, 1), again.entries.items.len);
    try std.testing.expectEqualStrings("Because \"LTO\"\nis on.", again.entries.items[0].reply);
    try std.testing.expectEqual(@as(i64, 100), again.entries.items[0].time);
    try std.testing.expectEqualStrings("é", cut("é", 2));
    try std.testing.expectEqualStrings("", cut("é", 1));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("3h ago", ago(&buf, 4 * 3600, 3600));
    try std.testing.expectEqualStrings("Nov 14, 2023", ago(&buf, 1800000000, 1700000000));
}
