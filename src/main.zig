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
const version = @import("build_options").version;
/// This platform's archive in each release, for the updater.
const asset = switch (@import("builtin").os.tag) {
    .macos => "nanoterm-macos-arm64.zip",
    .linux => "nanoterm-linux-" ++ @tagName(@import("builtin").cpu.arch) ++ ".tar.gz",
    .windows => "nanoterm-windows-" ++ @tagName(@import("builtin").cpu.arch) ++ ".zip",
    else => "",
};

fn updateReady(ctx: *anyopaque) void {
    const shared: *session_mod.Shared = @ptrCast(@alignCast(ctx));
    shared.redraw();
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    // Its version, as the updater checks a downloaded one.
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) {
        var buf: [64]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(init.io, &buf);
        w.interface.print("nanoterm {s}\n", .{if (version.len > 0) version else "dev"}) catch {};
        w.interface.flush() catch {};
        return;
    }
    // Started by an agent as its MCP server: show_visual, then nothing else.
    if (args.len == 4 and std.mem.eql(u8, args[1], "--mcp")) {
        @import("mcp_server.zig").serve(init.gpa, args[2], args[3]);
        return;
    }
    const app = try nanoui.App.create(init, .{ .name = "nanoterm" });
    defer app.destroy();

    // Windows has no HOME: the user's profile folder is it.
    if (@import("proc.zig").windows and init.environ_map.get("HOME") == null) {
        if (init.environ_map.get("USERPROFILE")) |p| try init.environ_map.put("HOME", p);
    }
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
    // Files the system opens with nanoterm: a tab each (open_files.zig).
    app.onOpenFiles(&w, @import("open_files.zig").open);
    first.queued_ask = ask;
    for (splits.items) |dir| w.splitFocused(if (std.mem.eql(u8, dir, "down")) .vertical else .horizontal);
    w.updater = try nanoui.Updater.start(init, .{
        .repo = "justrach/nanoterm",
        .asset = asset,
        .version = version,
        .name = "nanoterm",
        .changed = .{ .ctx = &shared, .func = updateReady },
    });
    defer w.updater.?.deinit();
    // graff kept current, as Harness keeps it: where nanoterm updates
    // itself (an installed app), and on Linux.
    const graff_update = @import("graff_update.zig");
    if (w.updater.?.phase.load(.acquire) != .off or @import("builtin").os.tag == .linux) {
        const search = @import("agents.zig").searchPath(init.arena.allocator(), init.environ_map.get("PATH") orelse "", init.environ_map.get("HOME") orelse "/");
        graff_update.global = try graff_update.Updater.create(init.gpa, init.io, init.environ_map, search);
    }
    if (graff_update.global) |g| {
        g.changed = .{ .ctx = &shared, .func = updateReady };
        g.start();
    }
    defer if (graff_update.global) |g| g.destroy();
    if (w.updater.?.current.len > 0) shared.prefs.telemetry.version = w.updater.?.current;
    shared.prefs.track("app_open", .{});
    // The first launch: a few choices before anything else.
    if (!shared.prefs.onboarded) w.overlay = .onboarding;
    try app.run();
}
