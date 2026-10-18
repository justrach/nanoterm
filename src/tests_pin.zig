//! What you run is read from its start: a long output does not drag the
//! view to its end; the command stays at the top. Scrolling yourself
//! leaves you where you scroll.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");

fn until(t: *ui.Tester, s: *session_mod.Session, comptime ok: fn (*session_mod.Session) bool) bool {
    var waited: f64 = 0;
    while (waited < 10) : (waited += 0.02) {
        nanoui.runFor(0.02);
        t.frame();
        if (ok(s)) return true;
    }
    return false;
}

/// Whether text `s` is within the window (every line is built; most are
/// scrolled out of it).
fn onScreen(t: *ui.Tester, s: []const u8) bool {
    const r = t.findText(s) orelse return false;
    return r.y >= 40 and r.y + r.h <= 500;
}

fn ready(s: *session_mod.Session) bool {
    return s.shell.phase == .ready and !s.shell.busy();
}

test "a long output stays at its start, under its command" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-pin";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    const s = try w.newTab(home);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 800, .height = 500, .theme = theme.ui() });
    defer t.deinit();
    try std.testing.expect(until(&t, s, ready));
    s.run("echo before");
    try std.testing.expect(until(&t, s, ready));
    s.run("seq 1 300");
    try std.testing.expect(until(&t, s, ready));
    t.settle(1);
    // The command and the first lines show; the end does not.
    const cmd = t.findText("seq 1 300") orelse return error.CommandNotShown;
    try std.testing.expect(cmd.y > 30 and cmd.y < 140);
    try std.testing.expect(onScreen(&t, "1"));
    try std.testing.expect(!onScreen(&t, "300"));
    // Its command shows once: not also as the pinned header.
    try std.testing.expect(s.sticky == null);
    try t.screenshot("/tmp/nanoterm-pin.png");
    // Scrolled down by the reader: they stay where they scroll.
    for (0..80) |_| t.scroll(400, 300, -120);
    t.settle(1);
    try std.testing.expect(onScreen(&t, "300"));
    // A new command comes into view, at the top again if it is long.
    s.run("seq 1 200");
    try std.testing.expect(until(&t, s, ready));
    t.settle(1);
    try std.testing.expect(onScreen(&t, "seq 1 200"));
    try std.testing.expect(!onScreen(&t, "200"));
}
