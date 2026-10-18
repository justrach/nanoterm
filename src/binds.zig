//! nanoterm's key bindings, written once as on the Mac ("Cmd+D") and made
//! the platform's: on Linux and Windows a terminal leaves Control to the
//! programs it runs (^D, ^W, ^T mean something to vim and the shell), so
//! app shortcuts take Ctrl+Shift there, as Ghostty's do (split right
//! Ctrl+Shift+O, down Ctrl+Shift+E, tabs Alt+1…9). Menus, key handling and
//! the labels shown all come from here.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const S = nanoui.ui.Shortcut;

pub const mac = builtin.os.tag == .macos;

/// Where Ctrl+Shift+<key> would collide, the other platforms' own choice.
const overrides = [_][2][]const u8{
    .{ "Cmd+D", "Ctrl+Shift+O" },
    .{ "Cmd+Shift+D", "Ctrl+Shift+E" },
    .{ "Cmd+}", "Ctrl+PageDown" },
    .{ "Cmd+{", "Ctrl+PageUp" },
    // Zoom keeps Ctrl alone, as terminals and browsers have it.
    .{ "Cmd+=", "Ctrl+=" },
    .{ "Cmd+-", "Ctrl+-" },
    .{ "Cmd+0", "Ctrl+0" },
};

/// The accelerator for this platform of `m`, a Mac one.
pub inline fn accel(comptime m: []const u8) []const u8 {
    if (mac) return m;
    return comptime blk: {
        @setEvalBranchQuota(20_000);
        for (overrides) |o| if (std.mem.eql(u8, o[0], m)) break :blk o[1];
        const tail = m[std.mem.lastIndexOfScalar(u8, m, '+').? + 1 ..];
        if (std.mem.startsWith(u8, m, "Cmd+") and tail.len == 1 and std.ascii.isDigit(tail[0]) and std.mem.count(u8, m, "+") == 1) break :blk "Alt+" ++ tail;
        if (std.mem.startsWith(u8, m, "Cmd+Ctrl+")) break :blk "Ctrl+Shift+Alt+" ++ m["Cmd+Ctrl+".len..];
        if (std.mem.startsWith(u8, m, "Cmd+Alt+")) break :blk "Ctrl+Alt+" ++ m["Cmd+Alt+".len..];
        if (std.mem.startsWith(u8, m, "Cmd+Shift+")) break :blk "Ctrl+Shift+" ++ m["Cmd+Shift+".len..];
        if (std.mem.startsWith(u8, m, "Cmd+")) break :blk "Ctrl+Shift+" ++ m["Cmd+".len..];
        break :blk m;
    };
}

/// How the binding is shown: ⌘⇧D on the Mac, Ctrl+Shift+E elsewhere.
pub inline fn label(comptime m: []const u8) []const u8 {
    const a = comptime accel(m);
    if (!mac) return a;
    return comptime blk: {
        @setEvalBranchQuota(20_000);
        var out: []const u8 = "";
        var it = std.mem.splitScalar(u8, a, '+');
        while (it.next()) |p| {
            out = out ++ if (std.mem.eql(u8, p, "Cmd")) "⌘" else if (std.mem.eql(u8, p, "Shift")) "⇧" else if (std.mem.eql(u8, p, "Alt")) "⌥" else if (std.mem.eql(u8, p, "Ctrl")) "⌃" else if (std.mem.eql(u8, p, "Enter")) "↩" else if (p.len == 1) &[1]u8{std.ascii.toUpper(p[0])} else p;
        }
        break :blk out;
    };
}

/// The key combination the view checks for (`c.shortcut(binds.shortcut("Cmd+P"))`).
pub inline fn shortcut(comptime m: []const u8) S {
    const a = comptime accel(m);
    return comptime blk: {
        @setEvalBranchQuota(20_000);
        var s: S = .{ .key = 0 };
        var it = std.mem.splitScalar(u8, a, '+');
        while (it.next()) |p| {
            if (std.mem.eql(u8, p, "Cmd")) s.cmd = true else if (std.mem.eql(u8, p, "Ctrl")) s.ctrl = true else if (std.mem.eql(u8, p, "Shift")) s.shift = true else if (std.mem.eql(u8, p, "Alt")) s.alt = true else if (std.mem.eql(u8, p, "Up")) s.key = S.up else if (std.mem.eql(u8, p, "Down")) s.key = S.down else if (std.mem.eql(u8, p, "Enter")) s.key = S.enter else s.key = std.ascii.toLower(p[0]);
        }
        break :blk s;
    };
}

test "bindings per platform" {
    if (mac) {
        try std.testing.expectEqualStrings("⌘⇧D", label("Cmd+Shift+D"));
        try std.testing.expect(shortcut("Cmd+P").cmd);
    } else {
        try std.testing.expectEqualStrings("Ctrl+Shift+O", accel("Cmd+D"));
        try std.testing.expectEqualStrings("Ctrl+Shift+E", label("Cmd+Shift+D"));
        try std.testing.expectEqualStrings("Alt+3", accel("Cmd+3"));
        try std.testing.expectEqualStrings("Ctrl+Alt+Left", accel("Cmd+Alt+Left"));
        const p = shortcut("Cmd+P");
        try std.testing.expect(p.ctrl and p.shift and !p.cmd and p.key == 'p');
    }
}
