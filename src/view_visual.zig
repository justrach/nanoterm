//! A visual in an agent's turn, drawn as Harness draws it (its
//! `crates/ui/src/visuals.rs`): a bordered card with the title and
//! "Native · Interactive", the script's tree, and a line on what it may
//! not reach. Stats are bordered tiles, charts horizontal bars from zero,
//! buttons accent plates, toggles a switch with On/Off, sliders a framed
//! track with their limits. A control's change goes to the script once the
//! card is drawn, and the next frame shows what it rendered.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const visual = @import("visual.zig");
const Node = visual.Node;
const more = @import("view_visual_more.zig");

/// What a control did this frame, for after the card is drawn.
pub const Event = struct { handler: u32, input: visual.Input };

/// Charts show this many bars, as Harness's.
const chart_bars = 12;

pub const Draw = struct {
    c: *ui.Context,
    event: ?Event = null,
    index: usize = 0,
};

pub fn card(c: *ui.Context, title: []const u8, v: *visual.Visual) void {
    ui.key(c, c.print("visual-{x}", .{@intFromPtr(v)}));
    var d: Draw = .{ .c = c };
    {
        const box = ui.div(c).column().wFull().bg(theme.panel).rounded(12).border(theme.border).clip();
        defer box.end();
        {
            const h = ui.div(c).row().wFull().gap(12).itemsCenter().px(18).py(13);
            defer h.end();
            {
                const t = ui.div(c).row().grow().clip();
                defer t.end();
                ui.text(c, title, .{ .size = 13, .weight = .semibold });
            }
            ui.text(c, if (v.err != null) "Stopped" else "Native · Interactive", .{ .size = 11, .color = theme.muted });
        }
        line(c);
        {
            const body = ui.div(c).column().wFull().p(18);
            defer body.end();
            if (v.err) |e| {
                const r = ui.div(c).column().wFull().gap(8).p(16).rounded(8).bg(theme.failure.alpha(0.08));
                defer r.end();
                ui.text(c, "This visual could not run", .{ .size = 13, .weight = .semibold, .color = theme.failure });
                ui.text(c, e, .{ .size = 13, .color = theme.failure, .wrap = true });
            } else if (v.tree) |*root| {
                node(&d, root, false);
            } else ui.text(c, "Preparing native visual…", .{ .size = 13, .color = theme.muted });
        }
        line(c);
        const f = ui.div(c).row().wFull().px(18).py(9);
        defer f.end();
        ui.text(c, "Isolated Luau · No network or filesystem", .{ .size = 11, .color = theme.muted });
    }
    if (d.event) |e| {
        v.call(e.handler, e.input);
        c.changed = true;
    }
}

fn line(c: *ui.Context) void {
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = theme.border }, .none, null);
}

/// Harness's numbers: 0; very large or small in e-notation; whole numbers
/// as they are; else two decimals.
pub fn number(c: *ui.Context, x: f64) []const u8 {
    if (x == 0) return "0";
    if (@abs(x) >= 1_000_000 or @abs(x) < 0.01) {
        const e = @floor(std.math.log10(@abs(x)));
        return c.print("{d:.2}e{d}", .{ x / std.math.pow(f64, 10, e), @as(i64, @intFromFloat(e)) });
    }
    if (@abs(x - @round(x)) < 0.000001) return c.print("{d:.0}", .{x});
    return c.print("{d:.2}", .{x});
}

/// A framed tile, as Harness's stats and charts: the deeper background, a
/// hairline, round corners.
pub fn tile(c: *ui.Context, grow: bool) ui.Div {
    const d = ui.div(c).column().p(16).rounded(10).border(theme.border).bg(theme.background);
    return if (grow) d.grow() else d.wFull();
}

pub fn node(d: *Draw, n: *const Node, in_row: bool) void {
    const c = d.c;
    d.index += 1;
    ui.key(c, c.print("n{d}", .{d.index}));
    switch (n.kind) {
        .column => {
            const col = ui.div(c).column().wFull().gap(14);
            defer col.end();
            for (n.children) |*ch| node(d, ch, false);
        },
        .row => {
            var r = ui.div(c).row().wFull().gap(14);
            r = if (allTiles(n.children)) r.itemsStretch() else r.itemsCenter();
            defer r.end();
            for (n.children) |*ch| node(d, ch, true);
        },
        .text => ui.text(c, n.text, .{ .size = 13, .wrap = true, .leading = 1.4 }),
        .stat => {
            const t = tile(c, in_row).minW(150);
            defer t.end();
            const text = if (n.label.len > 0) c.print("{s}: {s}", .{ n.label, n.text }) else n.text;
            ui.text(c, text, .{ .size = 20, .weight = .semibold, .wrap = true });
        },
        .chart => chart(c, n, in_row),
        .button => button(d, n),
        .toggle => toggle(d, n),
        .slider => slider(d, n, in_row),
        .rule => line(c),
        else => more.node(d, n, in_row),
    }
}

fn allTiles(children: []const Node) bool {
    for (children) |ch| if (ch.kind != .stat) return false;
    return children.len > 0;
}

fn label(n: *const Node, default: []const u8) []const u8 {
    return if (std.mem.trim(u8, n.text, " ").len > 0) n.text else default;
}

/// The frame of a button or toggle; its border lights on hover.
fn control(c: *ui.Context, fill: ui.Color, live: bool) ui.Div {
    const d = ui.div(c).row().gap(10).itemsCenter().px(14).py(9).rounded(8).border(theme.border_strong).bg(fill);
    c.node(d.index).style.min_height = 38;
    if (live and d.hovered()) c.node(d.index).style.border = theme.accent;
    return d;
}

fn button(d: *Draw, n: *const Node) void {
    const c = d.c;
    const live = n.handler != null;
    const b = control(c, theme.accent, live);
    defer b.end();
    if (b.clicked() and live) d.event = .{ .handler = n.handler.?, .input = .click };
    ui.text(c, label(n, "Run"), .{ .size = 13, .weight = .medium, .color = if (live) theme.on_accent else theme.muted });
}

fn toggle(d: *Draw, n: *const Node) void {
    const c = d.c;
    const on = n.value != 0;
    const live = n.handler != null;
    const b = control(c, theme.background, live);
    defer b.end();
    if (b.clicked() and live) d.event = .{ .handler = n.handler.?, .input = .{ .boolean = !on } };
    {
        var sw = ui.div(c).row().size(30, 18).roundedFull().px(3).itemsCenter().bg(if (on) theme.accent else theme.border_strong);
        if (on) sw = sw.justifyEnd();
        defer sw.end();
        _ = c.leaf(.{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .radius = 6, .background = theme.solid }, .none, null);
    }
    const color = if (live) theme.text else theme.muted;
    ui.text(c, label(n, "Toggle"), .{ .size = 13, .weight = .medium, .color = color });
    ui.text(c, if (on) "On" else "Off", .{ .size = 13, .weight = .medium, .color = color });
}

fn slider(d: *Draw, n: *const Node, in_row: bool) void {
    const c = d.c;
    const span = n.max - n.min;
    const value = std.math.clamp(n.value, n.min, n.max);
    const frac: f32 = if (span > 0) @floatCast((value - n.min) / span) else 0;
    const live = n.handler != null and span > 0;
    var box = ui.div(c).column().gap(5).p(12).rounded(8).border(theme.border);
    box = if (in_row) box.grow().minW(180) else box.wFull();
    defer box.end();
    {
        const r = ui.div(c).row().wFull().gap(12);
        defer r.end();
        ui.text(c, label(n, "Value"), .{ .size = 13 });
        ui.spacer(c);
        ui.text(c, number(c, value), .{ .size = 13 });
    }
    {
        // The track: a 4px bar, filled to the value, its knob there; a
        // press or drag anywhere on it sets the value.
        const area = ui.div(c).row().wFull().h(28).itemsCenter();
        defer area.end();
        const it = area.interaction();
        if (live and it.pressed) if (it.rect) |r| {
            const t = std.math.clamp((c.input.mouse.x - r.x) / @max(1, r.w), 0, 1);
            const next = n.min + @as(f64, t) * span;
            if (@abs(next - value) > span / 1000) d.event = .{ .handler = n.handler.?, .input = .{ .number = next } };
        };
        {
            const track = ui.div(c).row().grow().h(4).roundedFull().bg(theme.border_strong).clip();
            defer track.end();
            if (frac > 0) _ = c.leaf(.{ .grow = frac, .height = .{ .px = 4 }, .radius = 2, .background = theme.accent }, .none, null);
            if (frac < 1) _ = c.leaf(.{ .grow = 1 - frac }, .none, null);
        }
        const w = if (it.rect) |r| r.w else 0;
        _ = c.leaf(.{ .width = .{ .px = 14 }, .height = .{ .px = 14 }, .radius = 7, .background = theme.accent, .absolute = true, .offset = .{ .x = frac * w - 7, .y = 7 } }, .none, null);
    }
    const r = ui.div(c).row().wFull();
    defer r.end();
    ui.text(c, number(c, n.min), .{ .size = 11, .color = theme.muted });
    ui.spacer(c);
    ui.text(c, number(c, n.max), .{ .size = 11, .color = theme.muted });
}

/// Harness's chart: a row per value (the first twelve), its label, a bar
/// from zero (left for negatives), the number.
fn chart(c: *ui.Context, n: *const Node, in_row: bool) void {
    const t = tile(c, in_row).gap(10);
    defer t.end();
    ui.text(c, if (n.text.len > 0) n.text else "Chart", .{ .size = 13, .weight = .semibold });
    if (n.values.len == 0) ui.text(c, "No data yet", .{ .size = 13 });
    var scale: f64 = std.math.floatMin(f64);
    for (n.values) |x| scale = @max(scale, @abs(x));
    var lo: f64 = 0;
    var hi: f64 = 0;
    for (n.values) |x| {
        lo = @min(lo, x / scale);
        hi = @max(hi, x / scale);
    }
    const range = @max(hi - lo, std.math.floatMin(f64));
    const zero: f32 = @floatCast(-lo / range);
    for (n.values[0..@min(n.values.len, chart_bars)], 0..) |x, i| {
        const r = ui.div(c).row().wFull().gap(12).itemsCenter();
        defer r.end();
        c.node(r.index).style.min_height = 24;
        {
            const l = ui.div(c).row().w(82).clip();
            defer l.end();
            const name = if (i < n.labels.len and n.labels[i].len > 0) n.labels[i] else c.print("{d}", .{i + 1});
            ui.text(c, name, .{ .size = 12, .color = theme.muted });
        }
        {
            const track = ui.div(c).row().grow().h(18).bg(theme.panel).rounded(3).clip();
            defer track.end();
            const end: f32 = @floatCast((x / scale - lo) / range);
            const left = @min(zero, end);
            const width = @abs(end - zero);
            if (left > 0) _ = c.leaf(.{ .grow = left }, .none, null);
            if (width > 0) _ = c.leaf(.{ .grow = width, .height = .{ .px = 18 }, .radius = 3, .background = theme.accent }, .none, null);
            if (1 - left - width > 0.0001) _ = c.leaf(.{ .grow = 1 - left - width }, .none, null);
        }
        const v = ui.div(c).row().w(64);
        defer v.end();
        ui.text(c, number(c, x), .{ .size = 12 });
    }
    if (n.values.len > chart_bars) ui.text(c, c.print("Showing the first {d} of {d} values", .{ chart_bars, n.values.len }), .{ .size = 11, .color = theme.muted });
}
