//! The mouse in full-screen programs, through a real zsh and the real
//! view: a program that asks for drags in SGR's form (as Claude Code does)
//! gets a click and the wheel as reports at the cell, and records what
//! came; Shift-drag selects the screen's text instead and sends nothing.
//! The parser's side too: the modes programs set, and OSC 52 copies.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const view_screen = @import("view_screen.zig");
const theme = @import("theme.zig");
const Vt = @import("screen_vt.zig").Vt;

test "mouse modes and OSC 52 copies" {
    const gpa = std.testing.allocator;
    const v = try Vt.create(gpa, 20, 5);
    defer v.destroy();
    const s = v.screen;
    _ = v.feed("\x1b[?1000h\x1b[?1002h\x1b[?1006h");
    try std.testing.expectEqual(.drag, s.mouse);
    try std.testing.expect(s.mouse_sgr);
    // "hello" in base64; asking what's on the clipboard is not answered.
    _ = v.feed("\x1b]52;c;aGVsbG8=\x07\x1b]52;c;?\x07");
    try std.testing.expectEqualStrings("hello", s.copied.?);
    _ = v.feed("\x1b[?1006l\x1b[?1002l");
    try std.testing.expectEqual(.off, s.mouse);
    try std.testing.expect(!s.mouse_sgr);
}

fn until(t: *ui.Tester, s: *session_mod.Session, comptime ok: fn (*ui.Tester, *session_mod.Session) bool) bool {
    var waited: f64 = 0;
    while (waited < 10) : (waited += 0.02) {
        nanoui.runFor(0.02);
        t.frame();
        if (ok(t, s)) return true;
    }
    return false;
}

fn ready(_: *ui.Tester, s: *session_mod.Session) bool {
    return s.shell.phase == .ready and !s.shell.busy();
}

fn asking(t: *ui.Tester, s: *session_mod.Session) bool {
    const screen = s.shell.fullScreen() orelse return false;
    return screen.mouse == .drag and screen.origin != null and t.containsText("hello mouse");
}

test "a program that tracks the mouse gets clicks and the wheel; Shift selects" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-mouse";
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
    try t.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 560, .theme = theme.ui() });
    defer t.deinit();
    try std.testing.expect(until(&t, s, ready));

    // It asks for drags in SGR's form, then keeps the next 28 bytes it's sent.
    s.run("printf '\\033[?1049h\\033[?1002h\\033[?1006hhello mouse'; stty raw -echo; head -c 28 > got; stty sane; printf '\\033[?1006l\\033[?1002l\\033[?1049l'");
    try std.testing.expect(until(&t, s, asking));
    const screen = s.shell.fullScreen().?;
    const o = screen.origin.?;
    const m = view_screen.metrics(&t.ctx);

    // Shift-drag over its text: selected here, nothing sent.
    t.ctx.input.shift = true;
    t.drag(o[0] + 1, o[1] + m.h / 2, o[0] + 11 * m.w - 1, o[1] + m.h / 2);
    t.ctx.input.shift = false;
    try std.testing.expect(std.mem.indexOf(u8, t.ctx.selection.text.items, "hello mouse") != null);

    // A click at the third column of the second row, and a line of wheel.
    const x = o[0] + 2.5 * m.w;
    const y = o[1] + 1.5 * m.h;
    t.click(x, y);
    t.scroll(x, y, m.h);
    try std.testing.expect(until(&t, s, ready));
    try std.testing.expect(s.shell.fullScreen() == null);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[<0;3;2M\x1b[<0;3;2m\x1b[<64;3;2M", try std.Io.Dir.cwd().readFile(io, home ++ "/got", &buf));
}
