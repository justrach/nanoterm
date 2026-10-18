//! Find (⌘F) and zoom (⌘=) through the real view, on a real zsh's blocks.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");
const binds = @import("binds.zig");

fn until(t: *ui.Tester, s: *session_mod.Session, comptime ok: fn (*session_mod.Session) bool) bool {
    var waited: f64 = 0;
    while (waited < 10) : (waited += 0.02) {
        nanoui.runFor(0.02);
        t.frame();
        if (ok(s)) return true;
    }
    return false;
}

fn ready(s: *session_mod.Session) bool {
    return s.shell.phase == .ready and !s.shell.busy();
}

test "find steps through matches; zoom scales the text" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-find";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    const s = try w.newTab(home);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 600, .theme = theme.ui() });
    defer t.deinit();
    try std.testing.expect(until(&t, s, ready));
    s.run("printf 'alpha one\\nbeta\\nALPHA two\\n'");
    try std.testing.expect(until(&t, s, ready));

    try std.testing.expect(t.shortcut(binds.shortcut("Cmd+F")));
    try std.testing.expect(w.finding);
    t.typeText("alpha");
    t.settle(1);
    // The command has it twice, the output twice (case aside).
    try std.testing.expect(t.hasText("1 of 4"));
    t.key(.enter);
    try std.testing.expect(t.hasText("2 of 4"));
    try t.screenshot("/tmp/nanoterm-find.png");
    // Typing went to the find bar, not the input.
    try std.testing.expectEqual(@as(usize, 0), s.input.text().len);
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    try std.testing.expect(!w.finding);

    const before = t.findText("beta").?.h;
    try std.testing.expect(t.shortcut(binds.shortcut("Cmd+=")));
    try std.testing.expect(t.shortcut(binds.shortcut("Cmd+=")));
    t.settle(1);
    try std.testing.expect(t.findText("beta").?.h > before);
    try std.testing.expect(t.shortcut(binds.shortcut("Cmd+0")));
    try std.testing.expectEqual(@as(f32, 1), w.zoom);

    // A long output shows from its start, a pill going to its end.
    s.run("seq 1 300");
    try std.testing.expect(until(&t, s, ready));
    t.settle(1);
    try std.testing.expect(t.hasText("Jump to latest"));
    try std.testing.expect(s.sticky == null);
    t.scroll(400, 300, -400);
    t.settle(1);
    // The command, pinned while its output scrolls by.
    try std.testing.expect(s.sticky != null);
    try std.testing.expect(t.hasText("seq 1 300"));
    try t.screenshot("/tmp/nanoterm-jump.png");
    try t.clickText("Jump to latest");
    t.settle(1);
    try std.testing.expect(!t.hasText("Jump to latest"));
    try std.testing.expect(t.hasText("300"));
}
