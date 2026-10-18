//! The palette (⌘P) as a launcher: one search over the open sessions, the
//! session history (this run and before), actions, recent commands, and
//! the agent. Tab narrows it to one kind; the list is in sections, and the
//! row chosen is previewed at the side: a conversation's prompt and reply,
//! a pane's latest work, a command and where it runs.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const palette = @import("palette.zig");
const assist = @import("assist.zig");
const session_log = @import("session_log.zig");
const Workspace = @import("workspace.zig").Workspace;
const Session = @import("session.zig").Session;
const K = ui.keys.label;

/// Rows shown at once.
const rows = 7;
const list_height = 392;

pub fn card(c: *ui.Context, w: *Workspace) void {
    const width = @min(880, c.size.w - 40);
    const wide = width >= 720;
    const box = ui.div(c).column().w(width).bg(theme.panel).rounded(14).border(theme.border).shadowLg().clip();
    defer box.end();
    _ = box.interaction();
    var results: palette.Results = .{};
    palette.search(&results, c.alloc(), w, w.query.text(), w.scope);
    const items = results.entries.items;
    w.pick = @min(w.pick, items.len -| 1);
    var chosen: ?palette.Entry = null;
    {
        const h = ui.div(c).row().wFull().gap(10).itemsCenter().px(16).pt(14).pb(10);
        defer h.end();
        ui.icon(c, "magnifyingglass", .{ .size = 14, .color = theme.muted });
        const field = ui.div(c).row().grow();
        defer field.end();
        const id = c.peekId(null);
        c.focus = id;
        const r = ui.textField(c, &w.query, .{ .placeholder = "Search sessions, history, actions and commands, or ask…", .width = .fill, .size = 16 });
        if (r.changed) w.pick = 0;
        if (r.submitted and items.len > 0) chosen = items[w.pick];
    }
    scopes(c, w);
    rule(c);
    {
        const body = ui.div(c).row().wFull().h(list_height);
        defer body.end();
        {
            var list = ui.div(c).column().h(list_height).p(8).gap(1).clip();
            list = if (wide) list.w(width * 0.52) else list.wFull();
            defer list.end();
            if (listRows(c, w, &results)) |e| chosen = e;
            if (items.len == 0) empty(c, w);
        }
        if (wide) {
            _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = theme.border }, .none, null);
            const p = ui.div(c).column().grow().h(list_height).p(18).gap(12).clip();
            defer p.end();
            if (items.len > 0) preview(c, w, items[w.pick]);
        }
    }
    rule(c);
    footer(c, items.len);
    const e = chosen orelse return;
    open(w, e);
    c.changed = true;
}

fn rule(c: *ui.Context) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = theme.border }, .none, null);
}

fn scopes(c: *ui.Context, w: *Workspace) void {
    const r = ui.div(c).row().wFull().gap(6).itemsCenter().px(14).pb(10);
    defer r.end();
    for (std.enums.values(palette.Scope)) |sc| {
        ui.key(c, c.print("scope-{s}", .{@tagName(sc)}));
        const on = w.scope == sc;
        var d = ui.div(c).row().px(10).py(4).rounded(7);
        d = if (on) d.bg(theme.accent.alpha(0.16)) else d.hover(theme.block_hover);
        defer d.end();
        if (d.clicked()) {
            w.scope = sc;
            w.pick = 0;
            c.changed = true;
        }
        ui.text(c, sc.label(), .{ .size = 12, .weight = if (on) .semibold else .regular, .color = if (on) theme.accent else theme.muted });
    }
    ui.spacer(c);
    ui.kbd(c, "Tab");
    ui.text(c, "next", .{ .size = 11.5, .color = theme.faint });
}

fn basename(path: []const u8) []const u8 {
    const p = std.mem.trimEnd(u8, path, "/");
    return if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[i + 1 ..] else p;
}

fn firstLine(s: []const u8, max: usize) []const u8 {
    const line = s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
    return line[0..@min(line.len, max)];
}

const Row = struct { icon: []const u8, title: []const u8, detail: []const u8 = "", right: []const u8 = "", keys: bool = false, mono: bool = false, tint: ?ui.Color = null };

fn describe(c: *ui.Context, w: *Workspace, e: palette.Entry) Row {
    return switch (e) {
        .action => |a| .{ .icon = a.icon, .title = a.label, .right = a.keys, .keys = true },
        .run => |cmd| .{ .icon = "terminal", .title = cmd, .right = "run", .mono = true },
        .ask => |q| .{ .icon = "sparkles", .title = c.print("Ask {s}: {s}", .{ w.focused().which.label(), q }), .right = "ask", .tint = theme.agent },
        .pane => |s| .{ .icon = "terminal.fill", .title = c.print("{s} · {s}", .{ basename(s.cwd()), s.which.label() }), .detail = firstLine(palette.lastThing(s), 90), .right = if (s == w.focused()) "current" else "", .tint = if (s == w.focused()) theme.success else null },
        .ssh_host => |h| .{ .icon = "globe", .title = h, .detail = "connect in a new tab", .right = "ssh", .mono = true },
        .past => |i| blk: {
            const x = w.shared.log.entries.items[i];
            var buf: [32]u8 = undefined;
            break :blk .{ .icon = "sparkles", .title = firstLine(x.prompt, 100), .detail = c.print("{s} · {s} · {s}", .{ x.agent, session_log.ago(&buf, session_log.now(w.shared.io), x.time), basename(x.cwd) }), .right = if (live(w, x) != null) "open" else "" };
        },
    };
}

/// The rows in view, with their sections' titles; the one clicked.
fn listRows(c: *ui.Context, w: *Workspace, r: *const palette.Results) ?palette.Entry {
    const items = r.entries.items;
    const first = if (w.pick >= rows) w.pick + 1 - rows else 0;
    var chosen: ?palette.Entry = null;
    var shown_title = false;
    for (items[first..@min(items.len, first + rows)], first..) |e, i| {
        for (r.sections.items) |s| if (s.start == i or (!shown_title and s.start < i and sectionOf(r, i) == s.start)) {
            header(c, s.title);
        };
        shown_title = true;
        if (row(c, w, i, describe(c, w, e))) chosen = e;
    }
    return chosen;
}

fn sectionOf(r: *const palette.Results, i: usize) usize {
    var start: usize = 0;
    for (r.sections.items) |s| if (s.start <= i) {
        start = s.start;
    };
    return start;
}

fn header(c: *ui.Context, title: []const u8) void {
    const h = ui.div(c).row().wFull().px(10).pt(8).pb(3);
    defer h.end();
    ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = theme.faint });
}

fn row(c: *ui.Context, w: *Workspace, i: usize, r: Row) bool {
    ui.key(c, c.print("prow-{d}", .{i}));
    const picked = i == w.pick;
    var d = ui.div(c).row().wFull().gap(10).itemsCenter().px(10).py(6).rounded(8);
    d = if (picked) d.bg(theme.block_selected) else d.hover(theme.block_hover);
    defer d.end();
    const clicked = d.clicked();
    if (d.hovered()) w.pick = i;
    ui.icon(c, r.icon, .{ .size = 11, .frame = 16, .color = r.tint orelse if (picked) theme.accent else theme.muted });
    {
        const col = ui.div(c).column().gap(1).grow().clip();
        defer col.end();
        ui.text(c, r.title, .{ .size = 13, .mono = r.mono, .color = if (picked) theme.text else theme.text.alpha(0.85) });
        if (r.detail.len > 0) ui.text(c, r.detail, .{ .size = 11, .color = theme.faint });
    }
    if (r.right.len > 0) {
        if (r.keys) ui.kbd(c, r.right) else ui.text(c, r.right, .{ .size = 11.5, .color = theme.muted });
    }
    return clicked;
}

fn empty(c: *ui.Context, w: *Workspace) void {
    const d = ui.div(c).column().wFull().gap(6).p(16);
    defer d.end();
    const msg = switch (w.scope) {
        .history => "No conversations yet: what you ask the agent is kept here, across launches.",
        .commands => "No commands match.",
        else => "Nothing matches.",
    };
    ui.text(c, msg, .{ .size = 12.5, .color = theme.muted, .wrap = true });
}

fn footer(c: *ui.Context, n: usize) void {
    const f = ui.div(c).row().wFull().gap(14).itemsCenter().px(16).py(9);
    defer f.end();
    const hints = [_][2][]const u8{ .{ "↑↓", "move" }, .{ "↩", "open" }, .{ "Tab", "narrow" }, .{ "esc", "close" } };
    for (hints) |h| {
        const r = ui.div(c).row().gap(6).itemsCenter();
        defer r.end();
        ui.kbd(c, h[0]);
        ui.text(c, h[1], .{ .size = 11.5, .color = theme.faint });
    }
    ui.spacer(c);
    ui.text(c, c.print("{d} {s}", .{ n, if (n == 1) "result" else "results" }), .{ .size = 11.5, .color = theme.faint });
}

/// A history entry's pane and turn, if they are still open.
pub fn live(w: *Workspace, e: session_log.Entry) ?struct { *Session, *@import("agent.zig").Turn } {
    const t = e.turn orelse return null;
    const s = w.findSession(e.session) orelse return null;
    if (s.agent) |ag| for (ag.turns.items) |x| if (@as(*const anyopaque, x) == t) return .{ s, x };
    for (s.retired.items) |ag| for (ag.turns.items) |x| if (@as(*const anyopaque, x) == t) return .{ s, x };
    return null;
}

fn open(w: *Workspace, e: palette.Entry) void {
    w.closeOverlay();
    const s = w.focused();
    switch (e) {
        .action => |a| a.run(w),
        .run => |cmd| s.run(cmd),
        .ask => |q| assist.ask(s, q),
        .pane => |p| _ = w.focusSession(p),
        .ssh_host => |h| {
            // A new tab connecting: it runs once its shell is ready.
            const tab = w.newTab(s.cwd()) catch return;
            const cmd = std.fmt.allocPrint(tab.arena, "ssh {s}", .{h}) catch return;
            tab.queue.append(tab.gpa, cmd) catch {};
        },
        .past => |i| {
            const x = w.shared.log.entries.items[i];
            if (live(w, x)) |found| {
                _ = w.focusSession(found[0]);
                found[0].reveal = found[1];
            } else {
                // From an earlier launch: asked again, here.
                s.input.set(x.prompt);
                s.lock = .agent;
            }
        },
    }
}

fn preview(c: *ui.Context, w: *Workspace, e: palette.Entry) void {
    switch (e) {
        .past => |i| {
            const x = w.shared.log.entries.items[i];
            var buf: [32]u8 = undefined;
            ui.text(c, x.prompt[0..@min(x.prompt.len, 400)], .{ .size = 14.5, .weight = .semibold, .wrap = true, .leading = 1.35 });
            meta(c, &.{ x.agent, session_log.ago(&buf, session_log.now(w.shared.io), x.time), x.cwd });
            rule(c);
            if (x.reply.len > 0) ui.text(c, x.reply[0..@min(x.reply.len, 700)], .{ .size = 13, .color = theme.text.alpha(0.8), .wrap = true, .leading = 1.45 });
            ui.spacer(c);
            hint(c, if (live(w, x) != null) "Go to this conversation" else "Ask it again here");
        },
        .pane => |s| {
            ui.text(c, s.cwd(), .{ .size = 13.5, .weight = .semibold, .mono = true, .wrap = true });
            var turns: usize = 0;
            var cmds: usize = 0;
            for (s.timeline.items) |t| switch (t) {
                .turn => turns += 1,
                .block => cmds += 1,
            };
            meta(c, &.{ s.which.label(), c.print("{d} {s}", .{ cmds, if (cmds == 1) "command" else "commands" }), c.print("{d} {s}", .{ turns, if (turns == 1) "conversation" else "conversations" }) });
            rule(c);
            var i = s.timeline.items.len;
            var n: usize = 0;
            while (i > 0 and n < 7) : (n += 1) {
                i -= 1;
                const r = ui.div(c).row().wFull().gap(8).itemsCenter();
                defer r.end();
                switch (s.timeline.items[i]) {
                    .turn => |t| {
                        ui.icon(c, "sparkles", .{ .size = 10, .frame = 14, .color = theme.agent });
                        ui.text(c, firstLine(t.title orelse t.prompt, 80), .{ .size = 12.5 });
                    },
                    .block => |b| {
                        ui.icon(c, "terminal", .{ .size = 10, .frame = 14, .color = if (b.failed()) theme.failure else theme.muted });
                        ui.text(c, firstLine(b.command, 80), .{ .size = 12, .mono = true });
                    },
                }
            }
            if (s.timeline.items.len == 0) ui.text(c, "Nothing run here yet.", .{ .size = 12.5, .color = theme.muted });
            ui.spacer(c);
            hint(c, if (s == w.focused()) "Close and stay here" else "Go to this pane");
        },
        .ssh_host => |h| {
            ui.text(c, h, .{ .size = 14.5, .weight = .semibold, .mono = true, .wrap = true });
            meta(c, &.{ "SSH", "a new tab" });
            rule(c);
            ui.text(c, c.print("Opens `ssh {s}` with its connection shared. Once you have signed in, set nanoterm up from the session's bar: a block per command, the remote folder, and {s} working on the host.", .{ h, w.focused().which.label() }), .{ .size = 13, .color = theme.text.alpha(0.8), .wrap = true, .leading = 1.45 });
            ui.spacer(c);
            hint(c, "Connect");
        },
        .action => |a| {
            ui.text(c, a.label, .{ .size = 14.5, .weight = .semibold, .wrap = true });
            if (a.keys.len > 0) ui.kbd(c, a.keys);
            ui.spacer(c);
            hint(c, "Run it");
        },
        .run => |cmd| {
            const b = ui.div(c).column().wFull().px(12).py(10).bg(theme.code_bg).rounded(8).border(theme.border);
            {
                defer b.end();
                ui.text(c, cmd, .{ .size = 12.5, .mono = true, .wrap = true });
            }
            meta(c, &.{c.print("runs in {s}", .{w.focused().cwd()})});
            ui.spacer(c);
            hint(c, "Run it in this pane");
        },
        .ask => |q| {
            ui.text(c, q, .{ .size = 14.5, .weight = .semibold, .wrap = true });
            meta(c, &.{ w.focused().which.label(), w.focused().cwd() });
            ui.spacer(c);
            hint(c, c.print("Ask {s}", .{w.focused().which.label()}));
        },
    }
}

fn meta(c: *ui.Context, parts: []const []const u8) void {
    const r = ui.div(c).row().wFull().gap(6).itemsCenter().clip();
    defer r.end();
    for (parts, 0..) |p, i| {
        if (i > 0) ui.text(c, "·", .{ .size = 11.5, .color = theme.faint });
        ui.text(c, p, .{ .size = 11.5, .color = theme.muted });
    }
}

fn hint(c: *ui.Context, what: []const u8) void {
    const r = ui.div(c).row().gap(8).itemsCenter();
    defer r.end();
    ui.kbd(c, K("↩"));
    ui.text(c, what, .{ .size = 12, .color = theme.muted });
}
