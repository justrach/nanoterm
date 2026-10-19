//! An agent's turn: the prompt, then what the agent did in order — its
//! messages (light Markdown), thoughts, tool calls with their status, the
//! commands it ran (blocks), its plan, and questions waiting for an answer.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const agent_mod = @import("agent.zig");
const view_block = @import("view_block.zig");
const view_markdown = @import("view_markdown.zig");
const view_visual = @import("view_visual.zig");
const view_fold = @import("view_fold.zig");
const App = @import("session.zig").Session;

/// The width of an avatar and its gap: the turn's content starts after.
const gutter = 34;

pub fn turn(c: *ui.Context, app: *App, t: *agent_mod.Turn) void {
    ui.key(c, c.print("turn-{x}", .{@intFromPtr(t)}));
    const d = ui.div(c).column().wFull().px(16).py(14).gap(12);
    defer d.end();
    // The palette jumped here: say where, for the timeline to scroll.
    if (app.reveal == t) if (d.interaction().rect) |r| {
        app.shared.find.target_y = r.y;
        app.reveal = null;
    };
    {
        // You asked…
        const r = ui.div(c).row().wFull().gap(12);
        defer r.end();
        avatar(c, "person.fill", theme.accent);
        const q = ui.div(c).column().grow().pt(2);
        defer q.end();
        ui.text(c, t.title orelse t.prompt, .{ .size = 14.5, .weight = .semibold, .wrap = true, .leading = 1.35 });
        // The pictures that went with it.
        if (t.images.len > 0) {
            const pics = ui.div(c).row().gap(8).pt(8);
            defer pics.end();
            for (t.images) |im| _ = ui.image(c, .{ .key = c.print("turn-pic-{s}-{d}", .{ im.name, im.data.len }), .bytes = im.data, .max_width = 160, .max_height = 120, .radius = 8 });
        }
    }
    {
        // …and the agent answered.
        const h = ui.div(c).row().wFull().gap(12).itemsCenter();
        defer h.end();
        avatar(c, "sparkles", theme.agent);
        ui.text(c, t.agent.label(), .{ .size = 12.5, .weight = .semibold, .color = theme.agent });
        ui.spacer(c);
        if (!t.done) {
            ui.text(c, view_block.spin(c), .{ .size = 12, .color = theme.agent, .mono = true });
            ui.text(c, view_block.duration(c, @import("blocks.zig").now() - t.started), .{ .size = 11.5, .color = theme.muted, .mono = true });
        } else if (t.ended > 0) {
            ui.text(c, view_block.duration(c, t.ended - t.started), .{ .size = 11.5, .color = theme.muted, .mono = true });
        }
    }
    const body = ui.div(c).column().wFull().pl(gutter).gap(12);
    defer body.end();
    const items = t.items.items;
    const reply = view_fold.replyStart(items);
    var i: usize = 0;
    var ordinal: usize = 0;
    while (i < items.len) {
        if (view_fold.folds(items, i, reply)) {
            var j = i;
            while (j < items.len and view_fold.folds(items, j, reply)) j += 1;
            view_fold.group(c, app, t, i, j, ordinal, !t.done and j == items.len);
            ordinal += 1;
            i = j;
            continue;
        }
        item(c, app, t, &items[i]);
        i += 1;
    }
    if (!t.done and t.items.items.len == 0) ui.text(c, "Thinking…", .{ .size = 13.5, .color = theme.muted, .italic = true });
}

/// One item as it is drawn, in the reply or inside an open group.
pub fn item(c: *ui.Context, app: *App, t: *agent_mod.Turn, it: *agent_mod.Item) void {
    switch (it.*) {
        .text => |l| view_markdown.markdown(c, l.items),
        .thought => |l| thought(c, l.items),
        .tool => |*tl| if (!view_fold.isVisualTool(tl)) tool(c, app, tl),
        .visual => |sv| view_visual.card(c, sv.title, sv.v),
        .command => |b| if (!shownByTool(t, b)) view_block.block(c, app, b, true),
        .plan => |p| plan(c, p.items),
        .permission => |*p| permission(c, app, p),
        .note => |n| {
            const r = ui.div(c).row().gap(6).itemsCenter();
            defer r.end();
            ui.icon(c, "exclamationmark.triangle", .{ .size = 12, .color = theme.warning });
            ui.text(c, n, .{ .size = 13, .color = theme.warning, .wrap = true });
        },
    }
}

fn avatar(c: *ui.Context, icon: []const u8, color: ui.Color) void {
    const a = ui.div(c).row().size(22, 22).roundedFull().bg(color.alpha(0.16)).center();
    defer a.end();
    ui.icon(c, icon, .{ .size = 10.5, .color = color });
}

pub fn shownByTool(t: *agent_mod.Turn, b: *@import("blocks.zig").Block) bool {
    for (t.items.items) |it| switch (it) {
        .tool => |tl| if (tl.block == b) return true,
        else => {},
    };
    return false;
}

fn thought(c: *ui.Context, text: []const u8) void {
    const r = ui.div(c).row().wFull().gap(8);
    defer r.end();
    ui.icon(c, "brain", .{ .size = 11, .color = theme.faint });
    const shown = if (text.len > 600) c.print("{s}…", .{text[0..600]}) else text;
    ui.text(c, std.mem.trim(u8, shown, " \n"), .{ .size = 13, .color = theme.muted, .wrap = true, .italic = true, .leading = 1.4 });
}

fn toolIcon(kind: []const u8) []const u8 {
    const table = .{
        .{ "read", "doc.text" },      .{ "edit", "pencil" },     .{ "delete", "trash" },
        .{ "move", "arrow.right" },   .{ "search", "magnifyingglass" }, .{ "execute", "terminal" },
        .{ "think", "brain" },        .{ "fetch", "globe" },
    };
    inline for (table) |e| if (std.mem.eql(u8, kind, e[0])) return e[1];
    return "wrench.and.screwdriver";
}

fn tool(c: *ui.Context, app: *App, tl: *agent_mod.Tool) void {
    const col = ui.div(c).column().wFull().gap(6);
    defer col.end();
    {
        const r = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer r.end();
        ui.icon(c, toolIcon(tl.kind), .{ .size = 11, .frame = 14, .color = theme.muted });
        ui.text(c, if (tl.title.items.len > 0) tl.title.items else tl.kind, .{ .size = 13, .wrap = true });
        ui.spacer(c);
        switch (tl.status) {
            .pending, .in_progress => ui.text(c, view_block.spin(c), .{ .size = 12, .color = theme.accent, .mono = true }),
            .completed => ui.icon(c, "checkmark", .{ .size = 10, .weight = .bold, .color = theme.success }),
            .failed => ui.icon(c, "xmark", .{ .size = 10, .weight = .bold, .color = theme.failure }),
        }
    }
    if (tl.block) |b| {
        view_block.block(c, app, b, true);
    } else if (tl.detail.items.len > 0 and tl.status != .in_progress) {
        const d = tl.detail.items;
        const shown = if (d.len > 400) c.print("{s}…", .{d[0..400]}) else d;
        ui.text(c, shown, .{ .size = 11.5, .mono = true, .color = theme.faint, .wrap = true });
    }
}

fn plan(c: *ui.Context, entries: []const agent_mod.PlanEntry) void {
    const box = ui.div(c).column().wFull().p(10).gap(6).bg(theme.background).rounded(8).border(theme.border);
    defer box.end();
    ui.text(c, "Plan", .{ .size = 11.5, .weight = .semibold, .color = theme.muted });
    for (entries) |e| {
        const r = ui.div(c).row().gap(8).itemsCenter();
        defer r.end();
        const done = std.mem.eql(u8, e.status, "completed");
        const doing = std.mem.eql(u8, e.status, "in_progress");
        ui.icon(c, if (done) "checkmark.circle.fill" else if (doing) "circle.dotted" else "circle", .{ .size = 11, .color = if (done) theme.success else if (doing) theme.accent else theme.faint });
        ui.text(c, e.text, .{ .size = 13, .color = if (done) theme.muted else theme.text, .wrap = true });
    }
}

fn permission(c: *ui.Context, app: *App, p: *agent_mod.Permission) void {
    const box = ui.div(c).column().wFull().p(12).gap(10).bg(theme.background).rounded(8).border(if (p.chosen == null) theme.warning else theme.border);
    defer box.end();
    {
        const r = ui.div(c).row().gap(8).itemsCenter();
        defer r.end();
        ui.icon(c, "hand.raised", .{ .size = 12, .color = theme.warning });
        ui.text(c, p.title, .{ .size = 13, .weight = .semibold, .wrap = true });
    }
    if (p.chosen) |i| {
        ui.text(c, c.print("Answered: {s}", .{p.options[i].name}), .{ .size = 12, .color = theme.muted });
        return;
    }
    const r = ui.div(c).row().gap(8);
    defer r.end();
    for (p.options, 0..) |o, i| {
        const allow = std.mem.startsWith(u8, o.kind, "allow");
        const variant: ui.ButtonOptions = .{ .variant = if (allow and i == 0) .primary else if (allow) .secondary else .ghost, .size = 12.5 };
        if (ui.button(c, o.name, variant).clicked) if (app.agent) |ag| ag.answer(p, i);
    }
}
