//! Inside a block's output (pager.zig) with the input's keys: Vim's k climbs
//! into what a command printed, motions and search move through it, visual
//! mode and y copy from it, j off its end comes back; Emacs's M-v goes in,
//! the mark and M-w copy, C-g leaves. A real shell prints the output; the
//! Tester's clipboard takes the copies. HOME is a temporary folder.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");
const pager = @import("pager.zig");

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    shared: session_mod.Shared,
    w: ws_mod.Workspace,
    t: ui.Tester,

    fn init(f: *Fixture, home: []const u8, keys: ui.Keymap) !*session_mod.Session {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        f.arena = .init(gpa);
        std.Io.Dir.cwd().deleteTree(io, home) catch {};
        try std.Io.Dir.cwd().createDirPath(io, home);
        f.env = .init(f.arena.allocator());
        try f.env.put("HOME", home);
        try f.env.put("PATH", "/usr/bin:/bin");
        f.shared = try session_mod.Shared.init(gpa, io, f.arena.allocator(), &f.env);
        f.shared.wire();
        f.shared.prefs.keys = keys;
        f.w = .{ .shared = &f.shared, .nanoapp = undefined };
        const s = try f.w.newTab(home);
        try f.t.init(gpa, .init(&f.w, view.view), .{ .width = 900, .height = 600, .theme = theme.ui() });
        try f.until(struct {
            fn ok(x: *session_mod.Session) bool {
                return x.shell.cwd.items.len > 0 and !x.shell.busy();
            }
        }.ok);
        s.run("printf 'alpha one\\nbeta two\\ngamma three\\n'");
        try f.until(struct {
            fn ok(x: *session_mod.Session) bool {
                return !x.shell.busy() and pager.target(x) != null;
            }
        }.ok);
        f.t.settle(0.3);
        return s;
    }

    fn until(f: *Fixture, comptime done: fn (*session_mod.Session) bool) !void {
        const s = f.w.focused();
        var waited: f64 = 0;
        while (!done(s)) : (waited += 0.02) {
            if (waited > 10) return error.Timeout;
            nanoui.runFor(0.02);
            f.t.frame();
        }
    }

    fn deinit(f: *Fixture) void {
        pager.close();
        f.t.deinit();
        f.w.deinit();
        f.shared.deinit();
        f.arena.deinit();
    }
};

fn copied(t: *ui.Tester) []const u8 {
    return t.clipboard.items;
}

test "Vim: k climbs into the output; motions, search, visual and y; j comes back" {
    var f: Fixture = undefined;
    _ = try f.init("/tmp/nanoterm-test-pager-vim", .vim);
    defer f.deinit();
    const t = &f.t;
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    t.typeText("k");
    t.settle(0.2);
    const p = pager.open orelse return error.NotInside;
    try std.testing.expectEqual(@as(usize, 3), p.lineCount());
    try std.testing.expectEqual(@as(usize, 2), p.row());
    try std.testing.expect(t.hasText("gamma three") and t.hasText("NORMAL"));
    try t.screenshot("/tmp/nanoterm-pager.png");
    // gg to the first line, w to its second word, v e y copies it.
    t.typeText("ggwvey");
    try std.testing.expectEqualStrings("one", copied(t));
    // / searches; V y copies the line, its newline too.
    t.typeText("/beta");
    t.key(.enter);
    t.settle(0.1);
    try std.testing.expectEqual(@as(usize, 1), p.row());
    try std.testing.expectEqual(@as(usize, 0), p.col());
    t.typeText("Vy");
    try std.testing.expectEqualStrings("beta two\n", copied(t));
    // A count: 2yy, from the first line.
    t.typeText("gg2yy");
    try std.testing.expectEqualStrings("alpha one\nbeta two\n", copied(t));
    // $ and b; then G and j off the last line: back to the input.
    t.typeText("$b");
    try std.testing.expectEqual(@as(usize, 6), p.col());
    t.typeText("Gj");
    t.settle(0.2);
    try std.testing.expect(pager.open == null);
    try std.testing.expect(t.hasText("Run a command, or ask the agent anything") or t.hasText("NORMAL"));
}

test "Emacs: M-v goes in; C-p, the mark and M-w copy; C-g leaves" {
    var f: Fixture = undefined;
    _ = try f.init("/tmp/nanoterm-test-pager-emacs", .emacs);
    defer f.deinit();
    const t = &f.t;
    try std.testing.expect(t.shortcut(.{ .key = 'v', .alt = true }));
    t.settle(0.2);
    const p = pager.open orelse return error.NotInside;
    try std.testing.expect(t.hasText("EMACS"));
    try std.testing.expect(t.shortcut(.{ .key = 'p', .ctrl = true }));
    try std.testing.expect(t.shortcut(.{ .key = 'a', .ctrl = true }));
    try std.testing.expect(t.shortcut(.{ .key = ' ', .ctrl = true }));
    try std.testing.expect(t.shortcut(.{ .key = 'f', .alt = true }));
    try std.testing.expect(t.shortcut(.{ .key = 'w', .alt = true }));
    try std.testing.expectEqualStrings("beta", copied(t));
    try std.testing.expectEqual(@as(usize, 1), p.row());
    try std.testing.expect(t.shortcut(.{ .key = 'g', .ctrl = true }));
    t.settle(0.1);
    try std.testing.expect(pager.open == null);
}

test "the block's button opens it too, and closing the tab closes it" {
    var f: Fixture = undefined;
    const s = try f.init("/tmp/nanoterm-test-pager-button", .system);
    defer f.deinit();
    pager.enter(s, pager.target(s).?);
    f.t.settle(0.2);
    try std.testing.expect(f.t.hasText("alpha one"));
    // With the system's keys, arrows move and Esc leaves.
    try std.testing.expect(f.t.shortcut(.{ .key = ui.Shortcut.up }));
    try std.testing.expectEqual(@as(usize, 1), pager.open.?.row());
    try std.testing.expect(f.t.shortcut(.{ .key = ui.Shortcut.escape }));
    try std.testing.expect(pager.open == null);
}
