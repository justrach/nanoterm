//! Mermaid diagrams drawn in nanoterm's colors (`mermaid.zig` parses
//! them). Flowcharts and state diagrams are laid out in ranks: each node
//! one past the furthest node leading to it (loops broken where they turn
//! back), ordered within a rank by where its parents sit, edges drawn as
//! right-angled lines with arrowheads and labels; edges back up a rank go
//! round the side. Diamonds, hexagons and arrowheads are drawn in thin
//! strips. Sequence diagrams are drawn by `view_mermaid_seq.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const mm = @import("mermaid.zig");

pub const label_style: ui.TextStyle = .{ .size = 12.5 };
pub const small_style: ui.TextStyle = .{ .size = 11.5 };

/// Draws the diagram in `src`; false when it is a kind not drawn here.
pub fn diagram(c: *ui.Context, src: []const u8) bool {
    const d = mm.parse(c.alloc(), src);
    switch (d) {
        .flow => |f| if (f.nodes.len > 0) flow(c, f) else return false,
        .seq => |s| if (s.actors.len > 0) @import("view_mermaid_seq.zig").seq(c, s) else return false,
        .other => return false,
    }
    return true;
}

// Drawing in place: boxes at points within the diagram's box.

pub fn rect(c: *ui.Context, x: f32, y: f32, w: f32, h: f32, color: ui.Color, radius: f32) void {
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = @max(w, 0) }, .height = .{ .px = @max(h, 0) }, .background = color, .radius = radius }, .none, null);
}

/// A box with a border.
pub fn panel(c: *ui.Context, x: f32, y: f32, w: f32, h: f32, fill: ui.Color, edge: ui.Color, radius: f32) void {
    _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .width = .{ .px = w }, .height = .{ .px = h }, .background = fill, .border = edge, .border_width = 1.25, .radius = radius }, .none, null);
}

/// Lines of text centered in a box.
pub fn label(c: *ui.Context, x: f32, y: f32, w: f32, h: f32, text: []const u8, style: ui.TextStyle) void {
    const box = ui.div(c).absolute().offset(x, y).w(w).h(h).column().itemsCenter().justifyCenter();
    defer box.end();
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| ui.text(c, l, style);
}

/// The size of lines of text.
pub fn measure(c: *ui.Context, text: []const u8, style: ui.TextStyle) [2]f32 {
    var w: f32 = 0;
    var n: f32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        w = @max(w, c.text.width(l, style));
        n += 1;
    }
    return .{ @ceil(w), n * c.text.lineHeight(style) };
}

/// A horizontal or vertical line, dashed for a dotted edge.
pub fn line(c: *ui.Context, x0: f32, y0: f32, x1: f32, y1: f32, kind: mm.Line, color: ui.Color) void {
    if (kind == .invisible) return;
    const t: f32 = if (kind == .thick) 2.5 else 1.4;
    const horizontal = @abs(y1 - y0) < 0.5;
    const a = if (horizontal) @min(x0, x1) else @min(y0, y1);
    const b = if (horizontal) @max(x0, x1) else @max(y0, y1);
    if (kind != .dotted) {
        if (horizontal) rect(c, a, y0 - t / 2, b - a, t, color, 0) else rect(c, x0 - t / 2, a, t, b - a + t / 2, color, 0);
        return;
    }
    var p = a;
    while (p < b) : (p += 7) {
        const len = @min(4, b - p);
        if (horizontal) rect(c, p, y0 - t / 2, len, t, color, 0) else rect(c, x0 - t / 2, p, t, len, color, 0);
    }
}

/// An arrowhead with its tip at (x, y), pointing `dir`.
pub fn arrow(c: *ui.Context, x: f32, y: f32, dir: mm.Dir, color: ui.Color) void {
    const len: f32 = 8;
    const half: f32 = 4.5;
    var k: f32 = 0;
    while (k < len) : (k += 1) {
        const w = 2 * half * (k + 1) / len;
        switch (dir) {
            .down => rect(c, x - w / 2, y - k - 1, w, 1.2, color, 0),
            .up => rect(c, x - w / 2, y + k, w, 1.2, color, 0),
            .right => rect(c, x - k - 1, y - w / 2, 1.2, w, color, 0),
            .left => rect(c, x + k, y - w / 2, 1.2, w, color, 0),
        }
    }
}

/// A shape made of horizontal strips, `half(t)` its half width at height
/// `t` (0…1): a diamond, a hexagon. Its edge is the strips one color wider.
fn strips(c: *ui.Context, x: f32, y: f32, w: f32, h: f32, fill: ui.Color, edge: ui.Color, comptime half: fn (f32) f32) void {
    // Half-point strips: a pixel each on a Retina display.
    const step: f32 = 0.5;
    var row: f32 = 0;
    while (row < h) : (row += step) {
        const hw = half((row + step / 2) / h) * w / 2;
        rect(c, x + w / 2 - hw - 0.75, y + row, 2 * hw + 1.5, step, edge, 0);
    }
    row = 1.5;
    while (row < h - 1.5) : (row += step) {
        const hw = half((row + step / 2) / h) * w / 2 - 1.75;
        if (hw > 0) rect(c, x + w / 2 - hw, y + row, 2 * hw, step, fill, 0);
    }
}

fn diamondHalf(t: f32) f32 {
    return 1 - @abs(2 * t - 1);
}

fn hexagonHalf(t: f32) f32 {
    return @min(1, 0.72 + 0.28 * (1 - @abs(2 * t - 1)) / 0.5);
}

const Box = struct { x: f32 = 0, y: f32 = 0, w: f32, h: f32, rank: usize = 0, order: f32 = 0 };

fn flow(c: *ui.Context, f: mm.Flow) void {
    const a = c.alloc();
    const n = f.nodes.len;
    const boxes = a.alloc(Box, n) catch return;
    for (f.nodes, boxes) |node, *b| {
        const sz = measure(c, node.label, label_style);
        b.* = switch (node.shape) {
            .start, .end => .{ .w = 16, .h = 16 },
            .circle => blk: {
                const d = @max(sz[0], sz[1]) + 28;
                break :blk .{ .w = d, .h = d };
            },
            .diamond => .{ .w = sz[0] * 1.4 + 36, .h = sz[1] * 1.6 + 30 },
            .hexagon => .{ .w = sz[0] + 48, .h = sz[1] + 22 },
            else => .{ .w = sz[0] + 28, .h = sz[1] + 18 },
        };
    }
    const back = rank(a, f, boxes) catch return;
    order(a, f, boxes, back) catch return;

    // Ranks one after another along the flow; nodes side by side across.
    const vertical = f.dir == .down or f.dir == .up;
    const across_gap: f32 = 28;
    const along_gap: f32 = 54;
    var ranks: usize = 0;
    for (boxes) |b| ranks = @max(ranks, b.rank + 1);
    const thick = a.alloc(f32, ranks) catch return;
    const span = a.alloc(f32, ranks) catch return;
    @memset(thick, 0);
    @memset(span, 0);
    for (boxes) |b| {
        thick[b.rank] = @max(thick[b.rank], if (vertical) b.h else b.w);
        span[b.rank] += (if (vertical) b.w else b.h) + across_gap;
    }
    var widest: f32 = 0;
    for (span) |s| widest = @max(widest, s - across_gap);
    var along: f32 = 0;
    const starts = a.alloc(f32, ranks) catch return;
    for (0..ranks) |r| {
        starts[r] = along;
        along += thick[r] + along_gap;
    }
    along -= along_gap;
    // Across: each rank centered, in its order.
    const idx = a.alloc(usize, n) catch return;
    for (idx, 0..) |*v, i| v.* = i;
    std.mem.sort(usize, idx, boxes, struct {
        fn lt(bs: []Box, x: usize, y: usize) bool {
            return if (bs[x].rank != bs[y].rank) bs[x].rank < bs[y].rank else bs[x].order < bs[y].order;
        }
    }.lt);
    const cursor = a.alloc(f32, ranks) catch return;
    for (0..ranks) |r| cursor[r] = (widest - (span[r] - across_gap)) / 2;
    for (idx) |i| {
        const b = &boxes[i];
        const across = if (vertical) b.w else b.h;
        const pos = starts[b.rank] + ((thick[b.rank] - (if (vertical) b.h else b.w)) / 2);
        if (vertical) {
            b.x = cursor[b.rank];
            b.y = if (f.dir == .down) pos else along - pos - b.h;
        } else {
            b.y = cursor[b.rank];
            b.x = if (f.dir == .right) pos else along - pos - b.w;
        }
        cursor[b.rank] += across + across_gap;
    }
    // Room on the far side for edges that go back.
    var backs: f32 = 0;
    for (back) |is| if (is) {
        backs += 1;
    };
    const pad: f32 = 12;
    const W = (if (vertical) widest else along) + 2 * pad + backs * 10 + (if (backs > 0) @as(f32, 10) else 0);
    const H = (if (vertical) along else widest) + 2 * pad + (if (!vertical and backs > 0) backs * 10 + 10 else 0);
    for (boxes) |*b| {
        b.x += pad;
        b.y += pad;
    }

    const outer = ui.div(c).row().wFull().justifyCenter();
    defer outer.end();
    const canvas = ui.div(c).w(W).h(H);
    defer canvas.end();
    const ink = theme.muted;
    var back_k: f32 = 0;
    for (f.edges, 0..) |e, k| {
        if (e.from >= n or e.to >= n) continue;
        const s = boxes[e.from];
        const t = boxes[e.to];
        if (back[k]) {
            back_k += 1;
            backEdge(c, f.dir, s, t, e, W, H, back_k, ink);
        } else forwardEdge(c, f.dir, s, t, e, ink);
    }
    for (f.nodes, boxes) |node, b| shape(c, node, b);
}

/// Edges whose target is ranked before its source, in the order given.
fn rank(a: std.mem.Allocator, f: mm.Flow, boxes: []Box) ![]bool {
    const n = f.nodes.len;
    const back = try a.alloc(bool, f.edges.len);
    @memset(back, false);
    // Depth-first from each node in turn: an edge to a node on the path is a loop's turn back.
    const state = try a.alloc(u8, n);
    @memset(state, 0);
    var stack: std.ArrayList(struct { v: usize, next: usize }) = .empty;
    for (0..n) |root| {
        if (state[root] != 0) continue;
        try stack.append(a, .{ .v = root, .next = 0 });
        state[root] = 1;
        while (stack.items.len > 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.next >= f.edges.len) {
                state[top.v] = 2;
                _ = stack.pop();
                continue;
            }
            const k = top.next;
            top.next += 1;
            const e = f.edges[k];
            if (e.from != top.v or e.to >= n) continue;
            if (state[e.to] == 1) {
                back[k] = true;
            } else if (state[e.to] == 0) {
                state[e.to] = 1;
                try stack.append(a, .{ .v = e.to, .next = 0 });
            }
        }
    }
    // Longest path over the edges left: relax until nothing moves.
    var changed = true;
    var rounds: usize = 0;
    while (changed and rounds <= n) : (rounds += 1) {
        changed = false;
        for (f.edges, back) |e, is_back| {
            if (is_back or e.from >= n or e.to >= n) continue;
            if (boxes[e.to].rank < boxes[e.from].rank + 1) {
                boxes[e.to].rank = boxes[e.from].rank + 1;
                changed = true;
            }
        }
    }
    return back;
}

/// Order within ranks: as written, then twice by the parents' average place.
fn order(a: std.mem.Allocator, f: mm.Flow, boxes: []Box, back: []const bool) !void {
    for (boxes, 0..) |*b, i| b.order = @floatFromInt(i);
    const sum = try a.alloc(f32, boxes.len);
    const cnt = try a.alloc(f32, boxes.len);
    for (0..2) |_| {
        @memset(sum, 0);
        @memset(cnt, 0);
        for (f.edges, back) |e, is_back| {
            if (is_back or e.from >= boxes.len or e.to >= boxes.len) continue;
            sum[e.to] += boxes[e.from].order;
            cnt[e.to] += 1;
        }
        for (boxes, 0..) |*b, i| if (cnt[i] > 0) {
            b.order = sum[i] / cnt[i] + @as(f32, @floatFromInt(i)) * 0.001;
        };
    }
}

fn shape(c: *ui.Context, node: mm.Node, b: Box) void {
    // Opaque: the strips of a diamond overlap.
    const fill = if (node.shape == .diamond) theme.background.mix(theme.agent, 0.12) else theme.panel;
    const edge = if (node.shape == .diamond) theme.background.mix(theme.agent, 0.6) else theme.border_strong;
    switch (node.shape) {
        .start => return rect(c, b.x, b.y, b.w, b.h, theme.text, b.w / 2),
        .end => {
            panel(c, b.x, b.y, b.w, b.h, theme.background, theme.text, b.w / 2);
            rect(c, b.x + 4, b.y + 4, b.w - 8, b.h - 8, theme.text, (b.w - 8) / 2);
            return;
        },
        .diamond => strips(c, b.x, b.y, b.w, b.h, fill, edge, diamondHalf),
        .hexagon => strips(c, b.x, b.y, b.w, b.h, fill, edge, hexagonHalf),
        .circle, .stadium => panel(c, b.x, b.y, b.w, b.h, fill, edge, b.h / 2),
        .round, .cylinder => panel(c, b.x, b.y, b.w, b.h, fill, edge, 10),
        .subroutine => {
            panel(c, b.x, b.y, b.w, b.h, fill, edge, 3);
            rect(c, b.x + 6, b.y, 1.25, b.h, edge, 0);
            rect(c, b.x + b.w - 7, b.y, 1.25, b.h, edge, 0);
        },
        .rect, .flag => panel(c, b.x, b.y, b.w, b.h, fill, edge, 4),
    }
    label(c, b.x, b.y, b.w, b.h, node.label, label_style);
}

/// From the source's side facing the target to the target's facing side:
/// out, across at the middle of the gap, and in.
fn forwardEdge(c: *ui.Context, dir: mm.Dir, s: Box, t: Box, e: mm.Edge, ink: ui.Color) void {
    const vertical = dir == .down or dir == .up;
    if (vertical) {
        const sx = s.x + s.w / 2;
        const tx = t.x + t.w / 2;
        const down = t.y > s.y;
        const sy = if (down) s.y + s.h else s.y;
        const ty = if (down) t.y else t.y + t.h;
        // Across just before the target: an edge past a rank keeps to its
        // column, not across the nodes between.
        const mid = if (t.rank == s.rank + 1) (sy + ty) / 2 else if (down) ty - 22 else ty + 22;
        line(c, sx, sy, sx, mid, e.line, ink);
        line(c, sx, mid, tx, mid, e.line, ink);
        line(c, tx, mid, tx, ty, e.line, ink);
        if (e.head) arrow(c, tx, ty, if (down) .down else .up, ink);
        if (e.tail) arrow(c, sx, sy, if (down) .up else .down, ink);
        if (e.label.len > 0) edgeLabel(c, (sx + tx) / 2, if (@abs(sx - tx) < 1) (sy + ty) / 2 else mid, e.label);
    } else {
        const sy = s.y + s.h / 2;
        const ty = t.y + t.h / 2;
        const right = t.x > s.x;
        const sx = if (right) s.x + s.w else s.x;
        const tx = if (right) t.x else t.x + t.w;
        const mid = if (t.rank == s.rank + 1) (sx + tx) / 2 else if (right) tx - 22 else tx + 22;
        line(c, sx, sy, mid, sy, e.line, ink);
        line(c, mid, sy, mid, ty, e.line, ink);
        line(c, mid, ty, tx, ty, e.line, ink);
        if (e.head) arrow(c, tx, ty, if (right) .right else .left, ink);
        if (e.tail) arrow(c, sx, sy, if (right) .left else .right, ink);
        if (e.label.len > 0) edgeLabel(c, mid, (sy + ty) / 2, e.label);
    }
}

/// Round the diagram's far side, back to an earlier node.
fn backEdge(c: *ui.Context, dir: mm.Dir, s: Box, t: Box, e: mm.Edge, W: f32, H: f32, k: f32, ink: ui.Color) void {
    if (dir == .down or dir == .up) {
        const lane = W - 8 - (k - 1) * 10;
        const sy = s.y + s.h / 2;
        const ty = t.y + t.h / 2;
        line(c, s.x + s.w, sy, lane, sy, e.line, ink);
        line(c, lane, sy, lane, ty, e.line, ink);
        line(c, lane, ty, t.x + t.w, ty, e.line, ink);
        if (e.head) arrow(c, t.x + t.w, ty, .left, ink);
        if (e.label.len > 0) edgeLabel(c, lane, (sy + ty) / 2, e.label);
    } else {
        const lane = H - 8 - (k - 1) * 10;
        const sx = s.x + s.w / 2;
        const tx = t.x + t.w / 2;
        line(c, sx, s.y + s.h, sx, lane, e.line, ink);
        line(c, sx, lane, tx, lane, e.line, ink);
        line(c, tx, lane, tx, t.y + t.h, e.line, ink);
        if (e.head) arrow(c, tx, t.y + t.h, .up, ink);
        if (e.label.len > 0) edgeLabel(c, (sx + tx) / 2, lane, e.label);
    }
}

/// An edge's label on a patch of the background, centered at (x, y).
fn edgeLabel(c: *ui.Context, x: f32, y: f32, text: []const u8) void {
    const sz = measure(c, text, small_style);
    const w = sz[0] + 10;
    const h = sz[1] + 4;
    rect(c, x - w / 2, y - h / 2, w, h, theme.background, 4);
    var st = small_style;
    st.color = theme.muted;
    label(c, x - w / 2, y - h / 2, w, h, text, st);
}
