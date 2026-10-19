//! Mermaid's sequence diagrams: participants across the top (and again
//! at the bottom) with lifelines down, then each step in a row: messages
//! as arrows between lifelines with their text above (dashed for replies,
//! a loop back for one to itself), notes, and sections (`loop`, `alt`…).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const mm = @import("mermaid.zig");
const v = @import("view_mermaid.zig");

pub fn seq(c: *ui.Context, s: mm.Seq) void {
    const a = c.alloc();
    const n = s.actors.len;
    const widths = a.alloc(f32, n) catch return;
    const centers = a.alloc(f32, n) catch return;
    const box_h: f32 = 34;
    for (s.actors, widths) |actor, *w| w.* = @max(v.measure(c, actor.label, v.label_style)[0] + 28, 64);
    // Lifelines far enough apart for the boxes and the messages between.
    var x: f32 = 12 + widths[0] / 2;
    for (centers, 0..) |*cx, i| {
        if (i > 0) x += @max(widths[i - 1] / 2 + 36 + widths[i] / 2, 120);
        cx.* = x;
    }
    for (s.steps) |step| switch (step) {
        .message => |m| if (m.from != m.to) {
            const lo = @min(m.from, m.to);
            const hi = @max(m.from, m.to);
            const need = v.measure(c, m.text, v.small_style)[0] + 36;
            const have = centers[hi] - centers[lo];
            if (have < need) for (centers[hi..]) |*cx| {
                cx.* += need - have;
            };
        },
        .note => |nt| if (nt.from == nt.to and nt.side != .over) {
            const need = v.measure(c, nt.text, v.small_style)[0] + 40;
            const i = nt.from;
            if (nt.side == .right and i + 1 < n and centers[i + 1] - centers[i] < need) {
                const d = need - (centers[i + 1] - centers[i]);
                for (centers[i + 1 ..]) |*cx| cx.* += d;
            }
        },
        else => {},
    };
    // Rows, top to bottom.
    var y: f32 = 12 + box_h + 14;
    const rows = a.alloc(f32, s.steps.len) catch return;
    for (s.steps, rows) |step, *row| {
        row.* = y;
        y += switch (step) {
            .message => |m| v.measure(c, m.text, v.small_style)[1] + (if (m.from == m.to) @as(f32, 36) else 20),
            .note => |nt| v.measure(c, nt.text, v.small_style)[1] + 22,
            .section => 26,
        };
    }
    const bottom = y + 6;
    const W = centers[n - 1] + widths[n - 1] / 2 + 12 + 60;
    const H = bottom + box_h + 12;

    const outer = ui.div(c).row().wFull().justifyCenter();
    defer outer.end();
    const canvas = ui.div(c).w(W).h(H);
    defer canvas.end();
    const ink = theme.muted;
    for (centers) |cx| v.line(c, cx, 12 + box_h, cx, bottom, .dotted, theme.border_strong);
    for (s.steps, rows) |step, row| switch (step) {
        .message => |m| {
            const sz = v.measure(c, m.text, v.small_style);
            const x0 = centers[m.from];
            const x1 = centers[m.to];
            const kind: mm.Line = if (m.dashed) .dotted else .solid;
            if (m.from == m.to) {
                const ly = row + sz[1] + 4;
                v.line(c, x0, ly, x0 + 30, ly, kind, ink);
                v.line(c, x0 + 30, ly, x0 + 30, ly + 16, kind, ink);
                v.line(c, x0 + 30, ly + 16, x0, ly + 16, kind, ink);
                if (m.head) v.arrow(c, x0, ly + 16, .left, ink);
                v.label(c, x0 + 6, row, sz[0] + 8, sz[1], m.text, v.small_style);
            } else {
                const ly = row + sz[1] + 6;
                v.line(c, x0, ly, x1, ly, kind, ink);
                if (m.head) v.arrow(c, x1, ly, if (x1 > x0) .right else .left, ink);
                const mid = (x0 + x1) / 2;
                v.label(c, mid - sz[0] / 2 - 4, row, sz[0] + 8, sz[1], m.text, v.small_style);
            }
        },
        .note => |nt| {
            const sz = v.measure(c, nt.text, v.small_style);
            const w = sz[0] + 20;
            const h = sz[1] + 12;
            const nx = switch (nt.side) {
                .over => if (nt.from == nt.to) centers[nt.from] - w / 2 else centers[nt.from] - 20,
                .right => centers[nt.from] + 10,
                .left => centers[nt.from] - 10 - w,
            };
            const nw = if (nt.side == .over and nt.from != nt.to) centers[nt.to] - centers[nt.from] + 40 else w;
            v.panel(c, nx, row + 2, nw, h, theme.warning.alpha(0.14).mix(theme.background, 0.3), theme.warning.alpha(0.5), 4);
            v.label(c, nx, row + 2, nw, h, nt.text, v.small_style);
        },
        .section => |text| {
            const sz = v.measure(c, text, v.small_style);
            v.rect(c, 12, row + 12, W - 24, 1, theme.border, 0);
            v.panel(c, 12, row + 3, sz[0] + 16, sz[1] + 4, theme.background, theme.border_strong, 3);
            var st = v.small_style;
            st.weight = .semibold;
            st.color = theme.muted;
            v.label(c, 12, row + 3, sz[0] + 16, sz[1] + 4, text, st);
        },
    };
    for (s.actors, centers, widths) |actor, cx, w| {
        for ([_]f32{ 12, bottom }) |by| {
            v.panel(c, cx - w / 2, by, w, box_h, theme.panel, theme.border_strong, if (actor.person) box_h / 2 else 6);
            var st = v.label_style;
            st.weight = .medium;
            v.label(c, cx - w / 2, by, w, box_h, actor.label, st);
        }
    }
}
