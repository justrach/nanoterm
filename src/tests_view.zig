//! nanoterm's window as the user meets it, without a window: the real
//! view, driven by ui.Tester and rendered offscreen — the input telling
//! commands from requests, the history's suggestion, Tab, the palette.
//! A temporary HOME keeps the user's files, history and agents out.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");
const binds = @import("binds.zig");

test "the smart input, through the real view" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-view";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/src");
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    // Shared.init adds where tools live to PATH: no real agent here.
    try env.put("PATH", "/usr/bin:/bin");
    shared.history.add("git status");
    shared.history.add("ls -la");
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    const s = try w.newTab(home);

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1000, .height = 640, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);

    // The history suggests the rest; → takes it.
    t.typeText("git st");
    try std.testing.expect(t.hasText("atus"));
    try std.testing.expectEqual(session_mod.Mode.terminal, s.mode());
    try t.screenshot("/tmp/nanoterm-view-suggest.png");
    t.key(.right);
    try std.testing.expectEqualStrings("git status", s.input.text());

    // A question goes to the agent, and the pill says so.
    s.input.clear();
    t.frame();
    t.typeText("why is the build failing");
    try std.testing.expectEqual(session_mod.Mode.agent, s.mode());
    try std.testing.expect(t.hasText("agent"));
    try std.testing.expect(t.hasText("auto"));
    try t.screenshot("/tmp/nanoterm-view-agent.png");
    // ⌘I chooses the shell, and it stays chosen.
    try std.testing.expect(t.shortcut(binds.shortcut("Cmd+I")));
    try std.testing.expectEqual(session_mod.Mode.terminal, s.mode());
    try std.testing.expect(t.hasText("locked"));
    // Esc on an empty input goes back to detecting.
    s.input.clear();
    t.frame();
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    try std.testing.expect(s.lock == null);

    // Tab completes a folder.
    t.typeText("ls s");
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.tab }));
    t.frame();
    try std.testing.expectEqualStrings("ls src/", s.input.text());

    // ⌘P: the palette; typing filters it, ↩ runs the action.
    s.input.clear();
    try std.testing.expect(t.shortcut(binds.shortcut("Cmd+P")));
    try std.testing.expectEqual(ws_mod.Overlay.palette, w.overlay);
    t.typeText("split ri");
    t.settle(1);
    try std.testing.expect(t.hasText("Split right"));
    try t.screenshot("/tmp/nanoterm-view-palette.png");
    t.key(.enter);
    t.settle(1);
    try std.testing.expectEqual(ws_mod.Overlay.none, w.overlay);
    try std.testing.expectEqual(@as(usize, 2), ws_mod.Tree.count(w.tab().tree.root));

    // ⌘⇧M: the model picker opens on the pane's agent.
    try std.testing.expect(t.shortcut(binds.shortcut("Cmd+Shift+M")));
    t.settle(1);
    try std.testing.expect(t.hasText("Agent"));
    try std.testing.expect(t.hasText("Claude Code"));
    try t.screenshot("/tmp/nanoterm-view-models.png");
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    try std.testing.expectEqual(ws_mod.Overlay.none, w.overlay);
}

const agent_mod = @import("agent.zig");

const answer =
    \\## Why the build fails
    \\
    \\The linker can't find **`libfoo`**: the build script adds `-lfoo` but *never* the
    \\folder it lives in. See [the build docs](https://ziglang.org/learn/build-system/).
    \\
    \\1. Add the library path in `build.zig`
    \\2. Run the build again
    \\   - with `--verbose-link` to check
    \\- [x] Found the cause
    \\- [ ] Fix it
    \\
    \\```zig
    \\// build.zig
    \\pub fn build(b: *std.Build) void {
    \\    exe.addLibraryPath(.{ .cwd_relative = "/opt/foo/lib" });
    \\    exe.linkSystemLibrary("foo", .{});
    \\}
    \\```
    \\
    \\> This only matters on machines where foo is outside the default paths.
    \\
    \\| Option | Effect |
    \\|---|---|
    \\| `-lfoo` | link foo |
    \\| `-L` | add a search path |
;

test "an agent's answer, in Markdown" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-markdown";
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
    // A turn as an agent would have streamed it; no agent process runs.
    const ag = try agent_mod.Agent.create(gpa, io, .{ .ctx = s, .changed = session_mod.Session.changed, .newBlock = struct {
        fn f(_: *anyopaque, _: []const u8, _: []const u8) ?*@import("blocks.zig").Block {
            return null;
        }
    }.f }, .graff, home);
    s.agent = ag;
    try ag.promptAs("Why does the build fail?", "Why does the build fail?");
    const t = ag.current().?;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(gpa, answer);
    ag.addItem(t, .{ .text = text });
    t.done = true;
    t.ended = t.started + 12.4;
    try s.timeline.append(gpa, .{ .turn = t });

    var tester: ui.Tester = undefined;
    try tester.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 1100, .theme = theme.ui() });
    defer tester.deinit();
    tester.settle(1);
    try std.testing.expect(tester.hasText("Why the build fails"));
    try std.testing.expect(tester.hasText("Copy"));
    try tester.screenshot("/tmp/nanoterm-view-markdown.png");
    // Copy goes to the Tester's clipboard, never the system's.
    try tester.clickText("Copy");
    try std.testing.expect(std.mem.startsWith(u8, tester.clipboard.items, "// build.zig"));
}

test "a ready update shows in the title bar; one that can't install keeps nanoterm running" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-update";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var u: nanoui.Updater = .{ .gpa = gpa, .io = io, .options = .{ .repo = "justrach/nanoterm", .asset = "nanoterm-macos-arm64.zip", .name = "nanoterm" } };
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined, .updater = &u };
    defer w.deinit();
    _ = try w.newTab(home);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1000, .height = 640, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(!t.hasText("Restart to update"));
    u.version_buf[0..5].* = "9.9.9".*;
    u.version_len = 5;
    u.phase.store(.ready, .release);
    t.settle(1);
    // A card floats in asking to restart; nothing is staged here, so it
    // can't install, and nothing quits (quitting would reach the undefined app).
    t.settle(1);
    try std.testing.expect(t.hasText("nanoterm 9.9.9 is ready"));
    try t.screenshot("/tmp/nanoterm-update-card.png");
    try t.clickText("Restart now");
    t.settle(1);
    try std.testing.expectEqual(nanoui.update.Phase.ready, u.phase.load(.acquire));
    // "Later" puts it away; the title bar keeps a button.
    try t.clickText("Later");
    t.settle(1);
    try std.testing.expect(!t.hasText("nanoterm 9.9.9 is ready"));
    try std.testing.expect(t.hasText("Restart to update to 9.9.9"));
}
