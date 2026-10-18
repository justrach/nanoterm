//! Full-screen programs in a real zsh, through the real view: vim edits
//! and saves a file, less pages one and quits, each drawing over the pane
//! and taking the keys while it runs, then giving both back. Files stay
//! in a temporary HOME; vim reads no rc and writes no viminfo or swap.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");


/// Runs the loop and draws until `ok` holds, for up to 10 seconds.
fn until(t: *ui.Tester, s: *session_mod.Session, comptime ok: fn (*ui.Tester, *session_mod.Session) bool) bool {
    var waited: f64 = 0;
    while (waited < 10) : (waited += 0.02) {
        @import("nanoui").runFor(0.02);
        t.frame();
        if (ok(t, s)) return true;
    }
    return false;
}

fn ready(_: *ui.Tester, s: *session_mod.Session) bool {
    return s.shell.phase == .ready and !s.shell.busy();
}

fn full(_: *ui.Tester, s: *session_mod.Session) bool {
    return s.shell.fullScreen() != null;
}

fn drawn(t: *ui.Tester, s: *session_mod.Session) bool {
    return full(t, s) and t.containsText("~");
}

fn inserting(t: *ui.Tester, _: *session_mod.Session) bool {
    return t.containsText("hello screen");
}

fn paged(t: *ui.Tester, s: *session_mod.Session) bool {
    return full(t, s) and t.containsText("line 1") and !t.containsText("line 200");
}

fn first(t: *ui.Tester, _: *session_mod.Session) bool {
    return t.containsText("line 1 ");
}

fn second(t: *ui.Tester, _: *session_mod.Session) bool {
    return !t.containsText("line 1 ") and t.containsText("line 2");
}

test "vim and less draw over the pane and take the keys" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-screen";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    var lines: std.ArrayList(u8) = .empty;
    for (1..201) |i| try lines.print(arena, "line {d} \n", .{i});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/long.txt", .data = lines.items });
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
    try t.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 560, .theme = theme.ui() });
    defer t.deinit();
    try std.testing.expect(until(&t, s, ready));

    // vim: it fills the pane; keys go to it; :wq saves and gives it back.
    s.run("vim -u NONE -i NONE -n -N -c 'set number laststatus=2 ruler' note.txt");
    try std.testing.expect(until(&t, s, drawn));
    const screen = s.shell.fullScreen().?;
    try std.testing.expect(screen.rows >= 25 and screen.cols >= 90);
    t.typeText("ihello screen");
    try std.testing.expect(until(&t, s, inserting));
    try t.screenshot("/tmp/nanoterm-screen-vim.png");
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    t.typeText(":wq");
    t.key(.enter);
    try std.testing.expect(until(&t, s, ready));
    try std.testing.expect(s.shell.fullScreen() == null);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello screen\n", try std.Io.Dir.cwd().readFile(io, home ++ "/note.txt", &buf));
    const vim_block = s.timeline.items[s.timeline.items.len - 1].block;
    try std.testing.expectEqual(@as(?i32, 0), vim_block.exit_code);

    // less: a page of the file; ↓ scrolls a line; q quits.
    s.run("less long.txt");
    try std.testing.expect(until(&t, s, paged));
    try t.screenshot("/tmp/nanoterm-screen-less.png");
    t.key(.down);
    try std.testing.expect(until(&t, s, second));
    // The wheel scrolls it back up, as ↑ would.
    t.scroll(400, 300, 60);
    try std.testing.expect(until(&t, s, first));
    t.typeText("q");
    try std.testing.expect(until(&t, s, ready));
    try std.testing.expect(s.shell.fullScreen() == null);
    // The input is back.
    t.settle(1);
    try std.testing.expect(!t.containsText("line 2 "));
}
