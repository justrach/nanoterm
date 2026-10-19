//! A program that draws in place without the alternate screen, as Claude
//! Code's prompts do, through a real zsh and the real view: once it asks
//! for the terminal's input it gets a screen, keys go to it as a Mac
//! terminal sends them (Return picks, Option-Delete deletes a word),
//! and when it ends what it showed last stays in its block.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");

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
    return s.shell.fullScreen() != null and t.containsText("Yes, I trust this folder");
}

test "a prompt drawn in place gets a screen; Return reaches it; its last screen stays" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-inline";
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

    // A header, then a menu drawn and redrawn in place with bracketed
    // paste on; it keeps the one key it's sent.
    s.run("printf 'Accessing workspace\\n'; printf '\\033[?2004h\\033[?25l> 1. Yes\\n  2. No, exit\\n'; " ++
        "printf '\\033[2A\\033[2K> 1. Yes, I trust this folder\\n\\n'; stty raw -echo; head -c 9 > got; stty sane; " ++
        "printf '\\033[?2004l\\033[?25h'; echo chosen");
    try std.testing.expect(until(&t, s, asking));
    try std.testing.expect(t.containsText("Accessing workspace"));
    try std.testing.expect(t.containsText("No, exit"));

    // Keys with Option, Command and Shift, as Mac terminals send them:
    // Option-Delete a word, Command-Left the line's start, Option-Left a
    // word, Shift-Return a newline in the prompt; and the system's own
    // editing command (Command-Delete through key bindings).
    const in = &t.ctx.input;
    in.alt = true;
    t.key(.backspace);
    in.alt = false;
    in.cmd = true;
    t.key(.left);
    in.cmd = false;
    in.alt = true;
    t.key(.left);
    in.alt = false;
    in.shift = true;
    t.key(.enter);
    in.shift = false;
    in.ops = &.{.{ .command = .delete_to_line_start }};
    t.frame();
    t.key(.enter);
    try std.testing.expect(until(&t, s, ready));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b\x7f\x01\x1bb\x1b\r\x15\r", try std.Io.Dir.cwd().readFile(io, home ++ "/got", &buf));
    // The block keeps the prompt as it was last drawn, once, and the rest.
    const b = switch (s.timeline.items[s.timeline.items.len - 1]) {
        .block => |blk| blk,
        else => return error.NoBlock,
    };
    const text = try b.output.plainText(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("Accessing workspace\n> 1. Yes, I trust this folder\n  2. No, exit\nchosen", text);
}
