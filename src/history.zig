//! The commands run, shared by every pane as Warp shares them: zsh's own
//! history (read, never written), then nanoterm's (kept in its own file).
//! It suggests the rest of a command as it is typed, as fish and Warp do,
//! and gives ↑↓ and the palette the recent ones.
const std = @import("std");

/// The commands kept in memory and in the file.
const keep = 5000;

pub const History = struct {
    gpa: std.mem.Allocator,
    /// Oldest first; each once, at its latest use.
    items: std.ArrayList([]u8) = .empty,
    /// nanoterm's history file; null keeps it in memory (tests).
    path: ?[]const u8 = null,
    io: ?std.Io = null,

    pub fn deinit(h: *History) void {
        for (h.items.items) |s| h.gpa.free(s);
        h.items.deinit(h.gpa);
    }

    /// Adds `cmd` as the latest; an earlier copy moves up.
    pub fn add(h: *History, cmd_in: []const u8) void {
        const cmd = std.mem.trim(u8, cmd_in, " \t\r\n");
        if (cmd.len == 0 or cmd.len > 4096) return;
        for (h.items.items, 0..) |s, i| if (std.mem.eql(u8, s, cmd)) {
            const moved = h.items.orderedRemove(i);
            h.items.append(h.gpa, moved) catch h.gpa.free(moved);
            return;
        };
        const copy = h.gpa.dupe(u8, cmd) catch return;
        h.items.append(h.gpa, copy) catch return h.gpa.free(copy);
        if (h.items.items.len > keep) h.gpa.free(h.items.orderedRemove(0));
    }

    /// Adds `cmd` and appends it to the history file.
    pub fn record(h: *History, cmd: []const u8) void {
        h.add(cmd);
        const path = h.path orelse return;
        const io = h.io orelse return;
        if (std.mem.indexOfScalar(u8, cmd, '\n') != null) return;
        var file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return;
        defer file.close(io);
        const end = file.length(io) catch return;
        var buf: [4200]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s}\n", .{std.mem.trim(u8, cmd, " \t")}) catch return;
        file.writePositionalAll(io, line, end) catch {};
    }

    /// Loads zsh's history file (extended or plain) and then nanoterm's.
    pub fn load(h: *History, io: std.Io, zsh_path: []const u8, own_path: []const u8) void {
        h.loadFile(io, zsh_path, true);
        h.loadFile(io, own_path, false);
        h.path = own_path;
        h.io = io;
    }

    fn loadFile(h: *History, io: std.Io, path: []const u8, zsh: bool) void {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, h.gpa, .limited(8 * 1024 * 1024)) catch return;
        defer h.gpa.free(data);
        h.parse(data, zsh);
    }

    pub fn parse(h: *History, data: []const u8, zsh: bool) void {
        // Only the newest lines matter.
        var start: usize = 0;
        if (data.len > 512 * 1024) {
            start = data.len - 512 * 1024;
            while (start < data.len and data[start] != '\n') start += 1;
        }
        var lines = std.mem.splitScalar(u8, data[start..], '\n');
        var buf: [4096]u8 = undefined;
        var continued = false;
        while (lines.next()) |raw| {
            // A command over several lines ends its lines with '\': skip it.
            const ends_continued = raw.len > 0 and raw[raw.len - 1] == '\\';
            defer continued = ends_continued;
            if (continued or ends_continued) continue;
            var line = raw;
            if (zsh and std.mem.startsWith(u8, line, ": ")) {
                const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
                line = line[semi + 1 ..];
            }
            h.add(if (zsh) unmetafy(&buf, line) else line);
        }
    }

    /// The rest of the latest command that starts with `prefix`.
    pub fn suggest(h: *const History, prefix: []const u8) []const u8 {
        if (prefix.len == 0) return "";
        var i = h.items.items.len;
        while (i > 0) {
            i -= 1;
            const s = h.items.items[i];
            if (s.len > prefix.len and std.mem.startsWith(u8, s, prefix)) return s[prefix.len..];
        }
        return "";
    }

    /// The `n`th command back from the newest (0 is the newest).
    pub fn back(h: *const History, n: usize) ?[]const u8 {
        if (n >= h.items.items.len) return null;
        return h.items.items[h.items.items.len - 1 - n];
    }

    pub fn len(h: *const History) usize {
        return h.items.items.len;
    }
};

/// zsh writes bytes it treats specially as 0x83 then the byte xor 0x20.
fn unmetafy(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < buf.len) : (n += 1) {
        if (s[i] == 0x83 and i + 1 < s.len) {
            buf[n] = s[i + 1] ^ 0x20;
            i += 2;
        } else {
            buf[n] = s[i];
            i += 1;
        }
    }
    return buf[0..n];
}

test "history: zsh's file, dedup, suggestions" {
    var h: History = .{ .gpa = std.testing.allocator };
    defer h.deinit();
    h.parse(": 1700000000:0;git status\n: 1700000001:0;ls -la\n: 1700000002:0;echo a \\\nb\n: 1700000003:0;git stash\n", true);
    h.parse("git status\nzig build test\n", false);
    try std.testing.expectEqual(@as(usize, 4), h.len());
    try std.testing.expectEqualStrings("zig build test", h.back(0).?);
    try std.testing.expectEqualStrings("git status", h.back(1).?);
    // The latest match wins.
    try std.testing.expectEqualStrings(" status", h.suggest("git"));
    try std.testing.expectEqualStrings("ld test", h.suggest("zig bui"));
    try std.testing.expectEqualStrings("", h.suggest("zig build test"));
    try std.testing.expectEqualStrings("", h.suggest(""));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\xa3", unmetafy(&buf, "\x83\x83"));
}
