//! The tabs as a sidebar, after Harp (github.com/dominikmartn/harp): for
//! running agents side by side, one row per tab saying which needs you.
//! Rows are grouped by project (the repository, else the folder, a tab is
//! in), each group's header counting its tabs and those that need you.
//! A row shows the tab's name, how long since its agent last moved, and
//! its state: a turning ring while it works, an orange ring when it asks
//! you something, a filled check (bold name, a dot) when it finished
//! while you were elsewhere, a plain check once seen. It shows when
//! agents are in play (any tab has used one), or as View ▸ Show Sidebar
//! says.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const ws_mod = @import("workspace.zig");
const Workspace = ws_mod.Workspace;
const Tab = ws_mod.Tab;
const Session = @import("session.zig").Session;

pub const width: f32 = 248;

/// What a tab's row says.
pub const State = enum { idle, working, needs_you, done, failed };

/// What a row is made from: a tab's agent and shell, as they are now.
pub const Facts = struct {
    agent: bool = false,
    failed: bool = false,
    /// A turn is open (sent, not answered).
    turn_open: bool = false,
    /// The open turn asks a question no one has answered.
    asking: bool = false,
    turns_done: usize = 0,
    /// A command runs in the shell.
    shell_busy: bool = false,
    /// When the agent (or command) last moved: a turn began or ended.
    since: f64 = 0,
    /// The row's name: what the agent was first asked (else the tab's title).
    name: []const u8 = "",
};

pub fn state(f: Facts) State {
    if (f.agent) {
        if (f.failed) return .failed;
        if (f.turn_open) return if (f.asking) .needs_you else .working;
        if (f.turns_done > 0) return .done;
    }
    return if (f.shell_busy) .working else .idle;
}

/// A tab's facts, from its focused session (or what a test set).
pub fn facts(t: *const Tab) Facts {
    if (t.pretend) |p| return p;
    const s = t.session();
    var f: Facts = .{ .shell_busy = s.shell.busy() };
    const ag = s.agent orelse return f;
    f.agent = true;
    if (ag.turns.items.len > 0) {
        const first = ag.turns.items[0];
        const said = first.title orelse first.prompt;
        f.name = std.mem.trim(u8, said[0 .. std.mem.indexOfScalar(u8, said, '\n') orelse said.len], " ");
    }
    f.failed = ag.status == .failed;
    for (ag.turns.items) |turn| {
        if (turn.done) {
            f.turns_done += 1;
            f.since = @max(f.since, turn.ended);
        } else {
            f.turn_open = true;
            f.since = @max(f.since, turn.started);
            for (turn.items.items) |it| if (it == .permission and it.permission.chosen == null) {
                f.asking = true;
            };
        }
    }
    return f;
}

/// Whether the sidebar shows: as the user set it, else once agents are
/// in play.
pub fn shown(w: *const Workspace) bool {
    return switch (w.sidebar) {
        .shown => true,
        .hidden => false,
        .auto => anyAgent(w),
    };
}

/// Whether any tab has used an agent.
pub fn anyAgent(w: *const Workspace) bool {
    for (w.tabs.items) |t| if (facts(t).agent) return true;
    return false;
}

/// "now", "4m", "2h", "3d": how long ago `t`.
pub fn ago(buf: []u8, now: f64, t: f64) []const u8 {
    const s = @max(0, now - t);
    if (t <= 0 or s < 60) return "now";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d}m", .{@as(u32, @intFromFloat(s / 60))}) catch "";
    if (s < 86400) return std.fmt.bufPrint(buf, "{d}h", .{@as(u32, @intFromFloat(s / 3600))}) catch "";
    return std.fmt.bufPrint(buf, "{d}d", .{@as(u32, @intFromFloat(s / 86400))}) catch "";
}

/// The project a folder belongs to: its repository's name, else its own.
pub fn project(io: std.Io, home: []const u8, cwd: []const u8) []const u8 {
    if (std.mem.eql(u8, std.mem.trimEnd(u8, cwd, "/\\"), std.mem.trimEnd(u8, home, "/\\"))) return "~";
    var dir = cwd;
    var buf: [1024]u8 = undefined;
    while (dir.len > home.len) {
        const git = std.fmt.bufPrint(&buf, "{s}{c}.git", .{ dir, std.fs.path.sep }) catch break;
        if (std.Io.Dir.cwd().access(io, git, .{})) |_| return std.fs.path.basename(dir) else |_| {}
        dir = std.fs.path.dirname(dir) orelse break;
    }
    const base = std.fs.path.basename(cwd);
    return if (base.len == 0) cwd else base;
}

/// The tab's group, worked out again only when its folder changes.
fn group(w: *Workspace, t: *Tab) []const u8 {
    const cwd = t.session().cwd();
    if (!std.mem.eql(u8, t.group_cwd[0..t.group_cwd_len], cwd)) {
        const found = project(w.shared.io, w.shared.home, cwd);
        const n = @min(found.len, t.group_name.len);
        @memcpy(t.group_name[0..n], found[0..n]);
        t.group_name_len = n;
        const m = @min(cwd.len, t.group_cwd.len);
        @memcpy(t.group_cwd[0..m], cwd[0..m]);
        t.group_cwd_len = m;
    }
    return t.group_name[0..t.group_name_len];
}

pub fn draw(w: *Workspace, c: *ui.Context, title_height: f32) void {
    const side = ui.div(c).column().w(width).hFull().bg(theme.background.mix(theme.text, if (theme.dark) 0.04 else 0.035)).borderW(0);
    defer side.end();
    {
        // Under the traffic lights: hide the sidebar, a new tab.
        const top = ui.div(c).row().wFull().h(title_height).itemsCenter().px(10).gap(2);
        defer top.end();
        _ = c.leaf(.{ .width = .{ .px = 62 } }, .none, null);
        ui.spacer(c);
        ui.key(c, "sidebar-hide");
        if (ui.button(c, "", .{ .variant = .ghost, .size = 11, .icon = "sidebar.left" }).clicked) w.sidebar = .hidden;
        ui.key(c, "sidebar-new");
        if (ui.button(c, "", .{ .variant = .ghost, .size = 11, .icon = "plus" }).clicked) _ = w.newTab(w.focused().cwd()) catch {};
    }
    const list = ui.div(c).column().wFull().grow().px(8).pt(6).gap(1).scrollY();
    defer list.end();
    // Groups in the order their first tab has.
    var seen: [32][]const u8 = undefined;
    var n_groups: usize = 0;
    for (w.tabs.items) |t| {
        const g = group(w, t);
        const known = for (seen[0..n_groups]) |s| {
            if (std.mem.eql(u8, s, g)) break true;
        } else false;
        if (!known and n_groups < seen.len) {
            seen[n_groups] = g;
            n_groups += 1;
        }
    }
    const now = @import("blocks.zig").now();
    var select: ?usize = null;
    for (seen[0..n_groups], 0..) |g, gi| {
        var count: usize = 0;
        var needs: usize = 0;
        for (w.tabs.items) |t| if (std.mem.eql(u8, group(w, t), g)) {
            count += 1;
            if (state(facts(t)) == .needs_you) needs += 1;
        };
        ui.key(c, c.print("group-{s}", .{g}));
        const head = ui.div(c).row().wFull().itemsCenter().gap(6).px(10).pt(if (gi == 0) 4 else 14).pb(4);
        {
            defer head.end();
            ui.text(c, g, .{ .size = 12, .weight = .semibold, .color = theme.muted });
            ui.text(c, c.print("{d}", .{count}), .{ .size = 12, .color = theme.faint });
            ui.spacer(c);
            if (needs > 0) ui.text(c, c.print("{d} needs you", .{needs}), .{ .size = 12, .color = theme.warning });
        }
        for (w.tabs.items, 0..) |t, i| {
            if (!std.mem.eql(u8, group(w, t), g)) continue;
            if (row(w, c, t, i, now)) select = i;
        }
    }
    if (select) |i| w.selectTab(i);
}

/// A tab's row; true when clicked.
fn row(w: *Workspace, c: *ui.Context, t: *Tab, i: usize, now: f64) bool {
    const active = i == w.active;
    const f = facts(t);
    const st = state(f);
    const unread = st == .done and f.turns_done > t.seen_turns and !active;
    ui.key(c, c.print("tab-row-{x}", .{@intFromPtr(t)}));
    var r = ui.div(c).row().wFull().h(32).px(10).gap(8).itemsCenter().rounded(8);
    r = if (active) r.bg(theme.panel).border(theme.border).shadow(.{ .color = theme.shadow.alpha(0.06), .blur = 6, .y = 1 }) else r.hover(theme.block_hover);
    defer r.end();
    const clicked = r.clicked();
    {
        const label = ui.div(c).row().grow().clip();
        defer label.end();
        ui.text(c, name(t), .{ .size = 13.5, .weight = if (unread) .bold else .regular, .color = theme.text });
    }
    if (st != .idle) {
        var buf: [16]u8 = undefined;
        ui.text(c, c.print("{s}", .{ago(&buf, now, f.since)}), .{ .size = 12, .color = theme.muted });
    }
    mark(c, st, unread, now);
    return clicked and !active;
}

/// A row's state as a mark 16 wide.
fn mark(c: *ui.Context, st: State, unread: bool, now: f64) void {
    const box = ui.div(c).w(16).h(16).center();
    defer box.end();
    switch (st) {
        .idle => {},
        .working => spinner(c, now),
        .needs_you => {
            const ring = ui.div(c).w(15).h(15).roundedFull().border(theme.warning).borderW(1.6).center();
            defer ring.end();
            const dot = ui.div(c).w(6).h(6).roundedFull().bg(theme.warning);
            dot.end();
        },
        .done => if (unread) {
            const disc = ui.div(c).w(15).h(15).roundedFull().bg(theme.text).center();
            {
                defer disc.end();
                ui.icon(c, "checkmark", .{ .size = 8.5, .weight = .bold, .color = theme.background });
            }
            const dot = ui.div(c).absolute().offset(12, -1).w(5).h(5).roundedFull().bg(theme.muted);
            dot.end();
        } else ui.icon(c, "checkmark", .{ .size = 11, .weight = .semibold, .color = theme.faint }),
        .failed => ui.icon(c, "exclamationmark.triangle", .{ .size = 12, .color = theme.failure }),
    }
}

/// A ring that turns: three quarters of a circle of small discs, its gap
/// going round once a second.
fn spinner(c: *ui.Context, now: f64) void {
    c.animating = true;
    const n = 14;
    const r: f32 = 6.2;
    const turn: f32 = @floatCast(@mod(now, 1.0));
    for (0..n) |k| {
        const at = turn * std.math.tau + @as(f32, @floatFromInt(k)) / n * std.math.tau * 0.78;
        const x = 8 + r * @cos(at) - 1;
        const y = 8 + r * @sin(at) - 1;
        const d = ui.div(c).absolute().offset(x, y).w(2.1).h(2.1).roundedFull().bg(theme.text);
        d.end();
    }
}

/// A tab's name: what its agent was first asked, else its title.
pub fn name(t: *const Tab) []const u8 {
    const f = facts(t);
    return if (f.name.len > 0) f.name else t.session().title();
}

/// A folder as people write it: ~/code/app.
pub fn tilde(c: *ui.Context, home: []const u8, path: []const u8) []const u8 {
    if (home.len > 1 and std.mem.startsWith(u8, path, home) and (path.len == home.len or path[home.len] == std.fs.path.sep)) return c.print("~{s}", .{path[home.len..]});
    return path;
}

/// The title bar's "Working · 1m" for a tab, or null when idle.
pub fn statusLine(c: *ui.Context, t: *const Tab) ?[]const u8 {
    const f = facts(t);
    var buf: [16]u8 = undefined;
    const when = ago(&buf, @import("blocks.zig").now(), f.since);
    return switch (state(f)) {
        .idle => null,
        .working => c.print("Working · {s}", .{when}),
        .needs_you => c.print("Needs you · {s}", .{when}),
        .done => c.print("Done · {s}", .{when}),
        .failed => "Agent stopped",
    };
}

test "a row's state from its tab's facts" {
    try std.testing.expectEqual(State.idle, state(.{}));
    try std.testing.expectEqual(State.working, state(.{ .shell_busy = true }));
    try std.testing.expectEqual(State.working, state(.{ .agent = true, .turn_open = true }));
    try std.testing.expectEqual(State.needs_you, state(.{ .agent = true, .turn_open = true, .asking = true }));
    try std.testing.expectEqual(State.done, state(.{ .agent = true, .turns_done = 2 }));
    try std.testing.expectEqual(State.failed, state(.{ .agent = true, .failed = true, .turns_done = 2 }));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("now", ago(&buf, 100, 70));
    try std.testing.expectEqualStrings("4m", ago(&buf, 1000, 1000 - 245));
    try std.testing.expectEqualStrings("2h", ago(&buf, 10000, 10000 - 7300));
    try std.testing.expectEqualStrings("3d", ago(&buf, 300000, 300000 - 3 * 86400 - 5));
}
