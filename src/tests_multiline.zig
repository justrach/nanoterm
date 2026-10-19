//! The input as Harness's composer: a long request wraps and the pill
//! grows, Shift-Return starts a line, ↑ moves between the lines and only
//! from the first goes to the history, and a command of several lines runs
//! as one block. HOME is a temporary folder.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    shared: session_mod.Shared,
    w: ws_mod.Workspace,
    t: ui.Tester,

    fn init(f: *Fixture, home: []const u8) !void {
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
        f.w = .{ .shared = &f.shared, .nanoapp = undefined };
        _ = try f.w.newTab(home);
        try f.t.init(gpa, .init(&f.w, view.view), .{ .width = 900, .height = 700, .theme = theme.ui() });
        f.t.settle(1);
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
        f.w.deinit();
        f.shared.deinit();
        f.arena.deinit();
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
};

fn idle(x: *session_mod.Session) bool {
    return x.shell.phase != .starting and !x.shell.busy() and x.queue.items.len == 0;
}

test "the input wraps and grows; ↑ moves between its lines, then the history" {
    var f: Fixture = undefined;
    try f.init("/tmp/nanoterm-test-multiline");
    defer f.deinit();
    const t = &f.t;
    const s = f.w.focused();
    try f.until(idle);
    s.input.set("echo earlier");
    s.lock = .terminal;
    s.submit();
    s.lock = null;
    try f.until(idle);
    t.typeText("the lease was expecting five years, so the remaining two years technically carry over to the new tenant once the schedule is signed");
    t.frame();
    try std.testing.expect(s.input_lines[1] >= 2);
    try t.screenshot("/tmp/nanoterm-multiline.png");
    // Shift-Return: a new line, nothing sent.
    t.ctx.input.shift = true;
    t.key(.enter);
    t.ctx.input.shift = false;
    t.typeText("and one more line");
    t.frame();
    try std.testing.expect(std.mem.indexOfScalar(u8, s.input.text(), '\n') != null);
    try std.testing.expectEqual(session_mod.Mode.agent, s.mode());
    // ↑ off the last line: the input's, the text stays.
    const typed = try std.testing.allocator.dupe(u8, s.input.text());
    defer std.testing.allocator.free(typed);
    try std.testing.expect(!t.shortcut(.{ .key = ui.Shortcut.up }));
    t.textOps(&.{.{ .command = .move_up }});
    t.frame();
    try std.testing.expectEqualStrings(typed, s.input.text());
    try std.testing.expect(s.input_lines[0] + 1 < s.input_lines[1]);
    // On the first line, ↑ is the history's.
    t.textOps(&.{.{ .command = .move_up }});
    t.textOps(&.{.{ .command = .move_up }});
    t.textOps(&.{.{ .command = .move_up }});
    t.frame();
    try std.testing.expectEqual(@as(usize, 0), s.input_lines[0]);
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.up }));
    try std.testing.expectEqualStrings("echo earlier", s.input.text());
}

test "a command of several lines runs as one block" {
    var f: Fixture = undefined;
    try f.init("/tmp/nanoterm-test-multiline-run");
    defer f.deinit();
    const s = f.w.focused();
    try f.until(idle);
    s.lock = .terminal;
    s.run("echo one\necho two");
    try f.until(idle);
    const b = s.timeline.items[s.timeline.items.len - 1].block;
    try std.testing.expectEqual(@import("blocks.zig").State.done, b.state);
    const out = try b.output.plainText(std.testing.allocator);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "one") != null and std.mem.indexOf(u8, out, "two") != null);
    // One block for both lines.
    var count: usize = 0;
    for (s.timeline.items) |item| count += @intFromBool(item == .block);
    try std.testing.expectEqual(@as(usize, 1), count);
}
