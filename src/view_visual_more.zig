//! How nanoterm's own visual nodes are drawn (visual_more.zig): headings
//! and notes, a flow of steps (across when it fits, else down, as a
//! timeline), tabs, lists, tables, code, badges, progress and groups.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const visual = @import("visual.zig");
const vv = @import("view_visual.zig");
const Node = visual.Node;

fn toneColor(t: visual.Tone) ui.Color {
    return switch (t) {
        .neutral => theme.muted,
        .accent => theme.accent,
        .success => theme.success,
        .warning => theme.warning,
        .danger => theme.failure,
    };
}

pub fn node(d: *vv.Draw, n: *const Node, in_row: bool) void {
    const c = d.c;
    switch (n.kind) {
        .heading => ui.text(c, n.text, .{ .size = 15.5, .weight = .semibold, .wrap = true }),
        .note => ui.text(c, n.text, .{ .size = 12, .color = theme.muted, .wrap = true, .leading = 1.4 }),
        .code => {
            var b = ui.div(c).column().px(12).py(10).bg(theme.code_bg).rounded(8).border(theme.border);
            b = if (in_row) b.grow() else b.wFull();
            defer b.end();
            ui.text(c, n.text, .{ .size = 12, .mono = true, .wrap = true, .leading = 1.35 });
        },
        .badge => {
            const color = toneColor(n.tone);
            const b = ui.div(c).row().px(9).py(3).roundedFull().bg(color.alpha(0.14)).border(color.alpha(0.3));
            defer b.end();
            ui.text(c, n.text, .{ .size = 11.5, .weight = .semibold, .color = if (n.tone == .neutral) theme.text else color });
        },
        .progress => progress(c, n, in_row),
        .list => list(c, n, in_row),
        .table => table(c, n, in_row),
        .tabs => {
            var selected: usize = @intFromFloat(n.value - 1);
            if (ui.segmented(c, n.labels, &selected)) if (n.handler) |h| {
                d.event = .{ .handler = h, .input = .{ .number = @floatFromInt(selected + 1) } };
            };
        },
        .flow => flow(d, n),
        .group => {
            const p = vv.tile(c, in_row).gap(12);
            defer p.end();
            if (n.text.len > 0) ui.text(c, n.text, .{ .size = 13, .weight = .semibold });
            for (n.children) |*ch| vv.node(d, ch, false);
        },
        else => {},
    }
}

fn progress(c: *ui.Context, n: *const Node, in_row: bool) void {
    var col = ui.div(c).column().gap(6);
    col = if (in_row) col.grow() else col.wFull();
    defer col.end();
    {
        const r = ui.div(c).row().wFull().itemsCenter();
        defer r.end();
        ui.text(c, n.text, .{ .size = 13 });
        ui.spacer(c);
        ui.text(c, c.print("{d:.0}%", .{100 * n.value / n.max}), .{ .size = 13 });
    }
    const track = ui.div(c).row().wFull().h(4).roundedFull().bg(theme.border_strong).clip();
    defer track.end();
    const frac: f32 = @floatCast(n.value / n.max);
    if (frac > 0) _ = c.leaf(.{ .grow = frac, .height = .{ .px = 4 }, .radius = 2, .background = theme.accent }, .none, null);
    if (frac < 1) _ = c.leaf(.{ .grow = 1 - frac }, .none, null);
}

fn list(c: *ui.Context, n: *const Node, in_row: bool) void {
    var col = ui.div(c).column().gap(7);
    col = if (in_row) col.grow() else col.wFull();
    defer col.end();
    for (n.labels, 1..) |item, i| {
        const r = ui.div(c).row().wFull().gap(9);
        defer r.end();
        if (n.ordered) {
            const num = ui.div(c).row().w(18).justifyEnd();
            defer num.end();
            ui.text(c, c.print("{d}.", .{i}), .{ .size = 13, .leading = 1.4, .color = theme.muted });
        } else {
            const dot = ui.div(c).row().w(10).h(19).center();
            defer dot.end();
            _ = c.leaf(.{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .radius = 2.5, .background = theme.faint }, .none, null);
        }
        const t = ui.div(c).column().grow();
        defer t.end();
        ui.text(c, item, .{ .size = 13, .wrap = true, .leading = 1.4 });
    }
}

fn table(c: *ui.Context, n: *const Node, in_row: bool) void {
    var p = ui.div(c).column().rounded(10).border(theme.border).bg(theme.background).clip();
    p = if (in_row) p.grow() else p.wFull();
    defer p.end();
    if (n.labels.len > 0) {
        const h = ui.div(c).row().wFull().gap(12).px(16).py(9).bg(theme.panel);
        defer h.end();
        for (n.labels) |col| {
            const cell = ui.div(c).column().w(0).grow().clip();
            defer cell.end();
            ui.text(c, col, .{ .size = 11.5, .weight = .semibold, .color = theme.muted });
        }
    }
    for (n.rows, 0..) |row, i| {
        if (i > 0 or n.labels.len > 0) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = theme.border }, .none, null);
        const r = ui.div(c).row().wFull().gap(12).px(16).py(8);
        defer r.end();
        for (row, 0..) |cell, j| {
            // One line each: a wrapping cell would be measured at width 0.
            const box = ui.div(c).column().w(0).grow().clip();
            defer box.end();
            ui.text(c, cell, .{ .size = 12.5, .color = if (j == 0) theme.text else theme.text.alpha(0.8) });
        }
    }
}

/// Roughly how wide the steps are across, to choose across or down.
fn acrossWidth(n: *const Node) f32 {
    var w: f32 = 0;
    for (n.labels) |l| w += @as(f32, @floatFromInt(l.len)) * 7.2 + 64;
    return w;
}

/// Steps in order, the active one lit and those before it done; a click
/// goes to the script.
fn flow(d: *vv.Draw, n: *const Node) void {
    const c = d.c;
    const active: usize = @intFromFloat(n.value - 1);
    const col = ui.div(c).column().wFull().gap(10);
    defer col.end();
    if (n.text.len > 0) ui.text(c, n.text, .{ .size = 12.5, .weight = .semibold });
    // The card is at most 760 wide, less its padding and the pane's gutter.
    const room = @min(c.size.w - 120, 720);
    const across = acrossWidth(n) <= room;
    const steps = if (across) ui.div(c).row().wFull().gap(6).itemsCenter() else ui.div(c).column().wFull().gap(0);
    defer steps.end();
    for (n.labels, 0..) |label, i| {
        if (i > 0) {
            if (across) {
                ui.icon(c, "chevron.right", .{ .size = 9, .weight = .semibold, .color = theme.faint });
            } else {
                // The line between two numbers, down.
                const l = ui.div(c).row().pl(11).h(12);
                defer l.end();
                _ = c.leaf(.{ .width = .{ .px = 2 }, .height = .fill, .background = if (i <= active) theme.accent.alpha(0.6) else theme.border }, .none, null);
            }
        }
        ui.key(c, c.print("step{d}", .{i}));
        const lit = i == active;
        const done = i < active;
        const color = if (lit) theme.accent else if (done) theme.text else theme.muted;
        const it = ui.pressable(c, .{ .direction = .row, .gap = 8, .align_items = .center, .padding = .{ .left = 4, .right = 10, .top = 4, .bottom = 4 }, .radius = 8, .background = if (lit) theme.accent.alpha(0.14) else null, .border = if (lit) theme.accent else if (across) theme.border_strong else null, .control = true }, theme.block_hover);
        defer ui.end(c);
        if (it.clicked) if (n.handler) |h| {
            d.event = .{ .handler = h, .input = .{ .number = @floatFromInt(i + 1) } };
        };
        {
            const dot = ui.div(c).row().size(20, 20).roundedFull().center().bg(if (lit) theme.accent else if (done) theme.accent.alpha(0.25) else theme.panel).border(if (lit or done) theme.accent.alpha(0.5) else theme.border);
            defer dot.end();
            if (done) {
                ui.icon(c, "checkmark", .{ .size = 8.5, .weight = .bold, .color = theme.accent });
            } else ui.text(c, c.print("{d}", .{i + 1}), .{ .size = 10.5, .weight = .semibold, .color = if (lit) theme.background else theme.muted });
        }
        ui.text(c, label, .{ .size = 12.5, .weight = if (lit) .semibold else .regular, .color = color });
    }
}
