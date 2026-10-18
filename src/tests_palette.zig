//! The palette as a launcher, through the real view: sections for open
//! sessions, the session history (one from an earlier launch, read from
//! its file; one from this run, live), actions and commands; Tab narrows
//! it; ↩ jumps to a live conversation or asks an old one again.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const agent_mod = @import("agent.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");
const binds = @import("binds.zig");

test "⌘P: sessions, history across launches, scopes, jumping back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-palette";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const dir = home ++ "/Library/Application Support/nanoterm";
    try std.Io.Dir.cwd().createDirPath(io, dir);
    // An earlier launch's conversation.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/sessions.jsonl", .data = "{\"t\":1700000000,\"cwd\":\"/tmp/old-project\",\"agent\":\"graff\",\"prompt\":\"why does the release build take so long?\",\"reply\":\"LTO is on for every target.\"}\n" });
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("TMPDIR", home);
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    try std.testing.expectEqual(@as(usize, 1), shared.log.entries.items.len);
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    const first = try w.newTab(home);
    // This run's conversation, finished in the first pane.
    const ag = try agent_mod.Agent.create(gpa, io, .{ .ctx = first, .changed = session_mod.Session.changed, .newBlock = struct {
        fn f(_: *anyopaque, _: []const u8, _: []const u8) ?*@import("blocks.zig").Block {
            return null;
        }
    }.f }, .graff, home);
    first.agent = ag;
    try ag.promptAs(null, "explain the split tree");
    const turn = ag.current().?;
    turn.done = true;
    var reply: std.ArrayList(u8) = .empty;
    try reply.appendSlice(gpa, "A tab holds a tree of panes.");
    try turn.items.append(gpa, .{ .text = reply });
    try first.timeline.append(gpa, .{ .turn = turn });
    session_mod.Session.finished(first, turn);
    // A second tab, focused.
    const second = try w.newTab(home);
    try std.testing.expectEqual(second, w.focused());

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1000, .height = 720, .theme = theme.ui() });
    defer t.deinit();
    try std.testing.expect(t.shortcut(binds.shortcut("Cmd+P")));
    t.settle(1);
    try std.testing.expect(t.hasText("Open sessions"));
    try std.testing.expect(t.hasText("History"));
    try std.testing.expect(t.hasText("explain the split tree"));
    try std.testing.expect(t.hasText("why does the release build take so long?"));
    try t.screenshot("/tmp/nanoterm-palette.png");

    // Tab: History only; the preview shows the reply.
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.tab }));
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.tab }));
    t.settle(1);
    try std.testing.expectEqual(@import("palette.zig").Scope.history, w.scope);
    try std.testing.expect(!t.hasText("Open sessions"));
    try std.testing.expect(t.containsText("A tab holds a tree of panes."));
    try std.testing.expect(t.hasText("Go to this conversation"));
    try t.screenshot("/tmp/nanoterm-palette-history.png");
    // ↩ on this run's conversation: its pane, and the turn brought into view.
    t.key(.enter);
    t.settle(1);
    try std.testing.expectEqual(ws_mod.Overlay.none, w.overlay);
    try std.testing.expectEqual(first, w.focused());
    try std.testing.expectEqual(@as(usize, 0), w.active);

    // The earlier launch's: asked again, here.
    try std.testing.expect(t.shortcut(binds.shortcut("Cmd+P")));
    t.typeText("release build");
    t.settle(1);
    try std.testing.expect(t.hasText("Ask it again here"));
    t.key(.enter);
    t.settle(1);
    try std.testing.expectEqualStrings("why does the release build take so long?", first.input.text());
    try std.testing.expectEqual(@as(?session_mod.Mode, .agent), first.lock);

    // "light mode": Harness's light palette, kept for the next launch.
    first.input.clear();
    try std.testing.expect(t.shortcut(binds.shortcut("Cmd+P")));
    t.typeText("light mode");
    t.settle(1);
    try std.testing.expect(t.hasText("Appearance: Light"));
    t.key(.enter);
    t.settle(1);
    try std.testing.expectEqual(session_mod.Appearance.light, shared.appearance);
    try std.testing.expectEqual(theme.Appearance.light, theme.appearance);
    try std.testing.expectEqual(@as(u24, 0xfaf8f3), hex(theme.background));
    const kept = try std.Io.Dir.cwd().readFileAlloc(io, dir ++ "/appearance", arena, .limited(64));
    try std.testing.expectEqualStrings("light", kept);
    try std.testing.expect(t.shortcut(binds.shortcut("Cmd+P")));
    t.settle(1);
    try t.screenshot("/tmp/nanoterm-light.png");
    shared.setAppearance(.dark);
    t.settle(1);
    try t.screenshot("/tmp/nanoterm-dark.png");
    w.closeOverlay();
    try std.testing.expectEqual(@as(u24, 0x16140f), hex(theme.background));
}

fn hex(c: ui.Color) u24 {
    const r: u24 = @intFromFloat(@round(c.r * 255));
    const g: u24 = @intFromFloat(@round(c.g * 255));
    const b: u24 = @intFromFloat(@round(c.b * 255));
    return r << 16 | g << 8 | b;
}
