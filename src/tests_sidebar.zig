//! The tabs as a sidebar, through the real view: grouped by project, each
//! row's state, "needs you" counted, a finished turn unread until its tab
//! is looked at, a click choosing a tab. The agents are pretend (each
//! tab's facts set), the shells real, in a temporary HOME.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");
const sidebar = @import("view_sidebar.zig");

test "the sidebar: projects, states, needs you, unread until seen, a click" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-sidebar";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    // Two repositories and a folder that isn't one.
    for ([_][]const u8{ home ++ "/code/launchpad/.git", home ++ "/code/launchpad/web", home ++ "/code/ios-app/.git", home ++ "/notes" }) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();

    const Row = struct { dir: []const u8, facts: sidebar.Facts };
    const now = @import("blocks.zig").now();
    const rows = [_]Row{
        .{ .dir = home ++ "/code/launchpad", .facts = .{ .agent = true, .turn_open = true, .since = now - 70, .name = "landing-hero" } },
        .{ .dir = home ++ "/code/launchpad/web", .facts = .{ .agent = true, .turn_open = true, .asking = true, .since = now - 5, .name = "pricing-page" } },
        .{ .dir = home ++ "/code/launchpad", .facts = .{ .agent = true, .turns_done = 1, .since = now - 250, .name = "launch-thread" } },
        .{ .dir = home ++ "/code/ios-app", .facts = .{ .agent = true, .turns_done = 2, .since = now - 3700, .name = "onboarding-v2" } },
        .{ .dir = home ++ "/notes", .facts = .{} },
    };
    for (rows) |r| {
        _ = try w.newTab(r.dir);
        const t = w.tabs.items[w.tabs.items.len - 1];
        t.pretend = r.facts;
        // The shell starts in its folder (the sidebar groups by it).
        t.session().shell.cwd.clearRetainingCapacity();
        try t.session().shell.cwd.appendSlice(gpa, r.dir);
    }
    // onboarding-v2's turns were seen; launch-thread's wasn't.
    w.tabs.items[3].seen_turns = 2;
    w.selectTab(0);
    try std.testing.expectEqualStrings("launchpad", sidebar.project(io, home, home ++ "/code/launchpad/web"));
    try std.testing.expectEqualStrings("notes", sidebar.project(io, home, home ++ "/notes"));
    try std.testing.expectEqualStrings("~", sidebar.project(io, home, home));

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1100, .height = 640, .theme = theme.ui() });
    defer t.deinit();
    t.settle(0.5);
    try std.testing.expect(sidebar.shown(&w));
    for ([_][]const u8{ "launchpad", "ios-app", "notes", "landing-hero", "pricing-page", "launch-thread", "onboarding-v2", "1 needs you", "Working · 1m", "~/code/launchpad" }) |s| {
        if (!t.hasText(s)) {
            std.debug.print("missing: {s}\n", .{s});
            return error.TextMissing;
        }
    }
    // launchpad's three tabs are one group, before ios-app's.
    try std.testing.expect(t.findText("launch-thread").?.y < t.findText("ios-app").?.y);
    try std.testing.expect(t.findText("launchpad").?.y < t.findText("landing-hero").?.y);
    // launch-thread finished while unseen: unread until it's looked at.
    try std.testing.expect(w.tabs.items[2].seen_turns < 1);
    try t.screenshot("/tmp/nanoterm-sidebar.png");
    try t.clickText("launch-thread");
    t.settle(0.5);
    try std.testing.expectEqual(@as(usize, 2), w.active);
    try std.testing.expectEqual(@as(usize, 1), w.tabs.items[2].seen_turns);
    try std.testing.expect(t.hasText("Done · 4m"));
    // Hidden from the View menu: the tabs are back in the title bar.
    w.sidebar = .hidden;
    t.settle(0.5);
    try std.testing.expect(!t.hasText("1 needs you"));
}

test "a file opened with nanoterm: a tab in its folder, showing it; the fresh first tab gives way" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-open";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/docs");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/docs/REPORT.md", .data = "# Report\n" });
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    _ = try w.newTab(home);
    const open = @import("open_files.zig").open;
    open(&w, &.{home ++ "/docs/REPORT.md"});
    try std.testing.expectEqual(@as(usize, 1), w.tabs.items.len);
    const s = w.tab().session();
    try std.testing.expectEqualStrings(home ++ "/docs", s.cwd());
    try std.testing.expectEqualStrings("cat 'REPORT.md'", s.queue.items[0]);
    // A folder: a tab in it, beside the first (no longer fresh).
    open(&w, &.{home ++ "/docs"});
    try std.testing.expectEqual(@as(usize, 2), w.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), w.tab().session().queue.items.len);
}
