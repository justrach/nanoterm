//! nanoterm: a terminal of blocks with a coding agent, in the manner of
//! Warp, with Ghostty's splits and tabs, built on nanoui. Agents speak
//! ACP, as in Harness.
const std = @import("std");
const nanoui = @import("nanoui");
const session_mod = @import("session.zig");
const ws_mod = @import("workspace.zig");
const actions = @import("actions.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");
const Workspace = ws_mod.Workspace;
const Which = @import("agent.zig").Which;

/// The window is going: nothing may draw into it any more.
fn forget(ctx: *anyopaque, _: *nanoui.Window) void {
    const shared: *session_mod.Shared = @ptrCast(@alignCast(ctx));
    shared.window = null;
}

/// An update is ready: show it.
fn updateReady(ctx: *anyopaque) void {
    const shared: *session_mod.Shared = @ptrCast(@alignCast(ctx));
    shared.redraw();
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // Started by an agent as its MCP server: show_visual, then nothing else.
    if (args.len == 4 and std.mem.eql(u8, args[1], "--mcp")) {
        @import("mcp_server.zig").serve(init.gpa, args[2], args[3]);
        return;
    }
    const app = try nanoui.App.create(init, .{ .name = "nanoterm" });
    defer app.destroy();

    var shared = try session_mod.Shared.init(init.gpa, init.io, init.arena.allocator(), init.environ_map);
    shared.wire();
    defer shared.deinit();
    var w: Workspace = .{ .shared = &shared, .nanoapp = app, .zoom = shared.prefs.zoom };
    defer w.deinit();
    var acts: actions.Actions = .{ .w = &w };
    try actions.install(app, &acts);

    // nanoterm --cwd DIR --run "cmd" … --ask "prompt" --agent graff|claude
    //          --split right|down … (more panes, in the same directory)
    var start_dir: []const u8 = shared.home;
    var runs: std.ArrayList([]const u8) = .empty;
    defer runs.deinit(init.gpa);
    var splits: std.ArrayList([]const u8) = .empty;
    defer splits.deinit(init.gpa);
    var ask: ?[]const u8 = null;
    var which: ?Which = null;
    var i: usize = 1;
    while (i + 1 < args.len) : (i += 1) {
        const flag = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, flag, "--run")) {
            try runs.append(init.gpa, value);
        } else if (std.mem.eql(u8, flag, "--ask")) {
            ask = value;
        } else if (std.mem.eql(u8, flag, "--cwd")) {
            start_dir = value;
        } else if (std.mem.eql(u8, flag, "--agent")) {
            which = std.meta.stringToEnum(Which, value);
        } else if (std.mem.eql(u8, flag, "--split")) {
            try splits.append(init.gpa, value);
        } else continue;
        i += 1;
    }

    shared.window = try app.newWindow(.{
        .title = "nanoterm",
        .width = 1100,
        .height = 760,
        .min_width = 560,
        .min_height = 360,
        .title_bar = .hidden,
        .theme = theme.ui(),
        .content = .{ .view = .init(&w, view.view) },
        .on_close = .{ .ctx = &shared, .func = forget },
    });
    const first = try w.newTab(start_dir);
    if (which) |a| first.which = a;
    try first.queue.appendSlice(init.gpa, runs.items);
    first.queued_ask = ask;
    for (splits.items) |dir| w.splitFocused(if (std.mem.eql(u8, dir, "down")) .vertical else .horizontal);
    w.updater = try nanoui.Updater.start(init, .{
        .repo = "justrach/nanoterm",
        .asset = "nanoterm-macos-arm64.zip",
        .name = "nanoterm",
        .changed = .{ .ctx = &shared, .func = updateReady },
    });
    defer w.updater.?.deinit();
    try app.run();
}
