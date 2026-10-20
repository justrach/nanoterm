//! The PATH nanoterm's shells and agents get.
const std = @import("std");

/// Apps opened from the Finder get a bare PATH: add where tools live.
pub fn augment(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, home: []const u8) !void {
    // Windows apps get the user's whole PATH.
    if (@import("builtin").os.tag == .windows) return;
    var parts: std.ArrayList(u8) = .empty;
    try parts.appendSlice(arena, env.get("PATH") orelse "/usr/bin:/bin:/usr/sbin:/sbin");
    const extra = [_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/.local/bin", "/.bun/bin", "/.cargo/bin" };
    for (extra) |dir| {
        const full = if (dir[1] == '.') try std.fmt.allocPrint(arena, "{s}{s}", .{ home, dir }) else dir;
        if (std.mem.indexOf(u8, parts.items, full) == null) {
            try parts.append(arena, ':');
            try parts.appendSlice(arena, full);
        }
    }
    // nvm's newest node, for agents' adapters written in JavaScript.
    const nvm = try std.fmt.allocPrint(arena, "{s}/.nvm/versions/node", .{home});
    if (std.Io.Dir.cwd().openDir(io, nvm, .{ .iterate = true })) |dir_| {
        var dir = dir_;
        defer dir.close(io);
        var it = dir.iterate();
        var newest: ?[]const u8 = null;
        while (it.next(io) catch null) |e| {
            if (e.kind == .directory and (newest == null or std.mem.order(u8, e.name, newest.?) == .gt)) newest = try arena.dupe(u8, e.name);
        }
        if (newest) |v| {
            try parts.append(arena, ':');
            try parts.appendSlice(arena, try std.fmt.allocPrint(arena, "{s}/{s}/bin", .{ nvm, v }));
        }
    } else |_| {}
    try env.put("PATH", parts.items);
}
