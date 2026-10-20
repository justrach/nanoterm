//! Mermaid diagrams drawn in nanoterm's colors (`mermaid.zig` parses
//! them). Flowcharts and state diagrams are laid out in ranks: each node
//! one past the furthest node leading to it (loops broken where they turn
//! back), ordered within a rank by where its parents sit, edges drawn as
//! right-angled lines with arrowheads and labels; edges back up a rank go
//! round the side. An edge's label sits on its last stretch, into its
//! target, and the gap before a rank is made wide enough for the labels
//! of the edges into it, so labels never lie on nodes or on each other. Diamonds, hexagons and arrowheads are drawn in thin
//! strips. Sequence diagrams are drawn by `view_mermaid_seq.zig`.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const mm = @import("mermaid.zig");

pub const label_style: ui.TextStyle = .{ .size = 12.5 };
pub const small_style: ui.TextStyle = .{ .size = 11.5 };

/// Draws the diagram in `src`; false when it is a kind not drawn here.
/// `room`: the width it has.
pub fn diagram(c: *ui.Context, src: []const u8, room: f32) bool {
    const d = mm.parse(c.alloc(), src);
    switch (d) {
        .flow => |f| if (f.nodes.len > 0) flow(c, f, room) else return false,
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

/// A node's box; `r0`…`r1` its rank's extent along the flow; `lab` how
/// far along the flow the longest label of an edge into its rank reaches.
const Box = struct { x: f32 = 0, y: f32 = 0, w: f32, h: f32, rank: usize = 0, order: f32 = 0, r0: f32 = 0, r1: f32 = 0, lab: f32 = 0 };

fn flow(c: *ui.Context, f: mm.Flow, room: f32) void {
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
    // Each edge label's size, on its patch.
    const labels = a.alloc([2]f32, f.edges.len) catch return;
    for (f.edges, labels) |e, *l| l.* = if (e.label.len == 0) .{ 0, 0 } else patch(measure(c, e.label, small_style));

    // Too wide for its room: the other way round, if that is narrower (a
    // wide graph top-down is a tall one left-right, scrolled with the rest).
    var dir = f.dir;
    var size = place(a, dir, boxes, back, f.edges, labels) catch return;
    if (size[0] > room) {
        const turned: mm.Dir = switch (dir) {
            .down => .right,
            .up => .left,
            .right => .down,
            .left => .up,
        };
        const other = place(a, turned, boxes, back, f.edges, labels) catch return;
        if (other[0] < size[0]) {
            dir = turned;
            size = other;
        } else _ = place(a, dir, boxes, back, f.edges, labels) catch return;
    }
    // Still too wide: smaller, as far as stays readable.
    const k = std.math.clamp(room / size[0], min_scale, 1);
    for (boxes) |*b| {
        b.x *= k;
        b.y *= k;
        b.w *= k;
        b.h *= k;
        b.r0 *= k;
        b.r1 *= k;
        b.lab *= k;
    }
    const W = size[0] * k;
    const H = size[1] * k;

    const outer = ui.div(c).row().wFull().justifyCenter();
    defer outer.end();
    const canvas = ui.div(c).w(W).h(H);
    defer canvas.end();
    const ink = theme.muted;
    // Lines under the nodes, labels over everything.
    for ([_]Pass{ .lines, .labels }) |pass| {
        var back_k: f32 = 0;
        for (f.edges, 0..) |e, i| {
            if (e.from >= n or e.to >= n) continue;
            const s = boxes[e.from];
            const t = boxes[e.to];
            if (back[i]) {
                back_k += 1;
                backEdge(c, pass, dir, s, t, e, W, H, back_k, ink, k);
            } else forwardEdge(c, pass, dir, s, t, e, ink, k);
        }
        if (pass == .lines) for (f.nodes, boxes) |node, b| shape(c, node, b, k);
    }
}

const Pass = enum { lines, labels };

/// Along the flow, from a labeled edge's trunk to its target's rank: the
/// label, with room either side and for the arrowhead.
const label_room: f32 = 20;
/// From a rank to the trunk of the edges leaving it, at the least.
const trunk_room: f32 = 16;

/// The smallest a diagram is drawn to fit: its labels stay legible.
const min_scale: f32 = 0.62;

/// Places ranked, ordered boxes going `dir`; the diagram's size.
fn place(a: std.mem.Allocator, dir: mm.Dir, boxes: []Box, back: []const bool, edges: []const mm.Edge, labels: []const [2]f32) ![2]f32 {
    const n = boxes.len;
    // Ranks one after another along the flow; nodes side by side across.
    const vertical = dir == .down or dir == .up;
    const across_gap: f32 = 28;
    const along_gap: f32 = 54;
    var ranks: usize = 0;
    for (boxes) |b| ranks = @max(ranks, b.rank + 1);
    const thick = try a.alloc(f32, ranks);
    const span = try a.alloc(f32, ranks);
    @memset(thick, 0);
    @memset(span, 0);
    for (boxes) |b| {
        thick[b.rank] = @max(thick[b.rank], if (vertical) b.h else b.w);
        span[b.rank] += (if (vertical) b.w else b.h) + across_gap;
    }
    var widest: f32 = 0;
    for (span) |s| widest = @max(widest, s - across_gap);
    // The labels of edges into each rank, along the flow.
    const lab = try a.alloc(f32, ranks);
    @memset(lab, 0);
    for (edges, labels, back) |e, l, is_back| {
        if (is_back or e.to >= n or l[0] == 0) continue;
        const r = boxes[e.to].rank;
        lab[r] = @max(lab[r], if (vertical) l[1] else l[0]);
    }
    var along: f32 = 0;
    const starts = try a.alloc(f32, ranks);
    for (0..ranks) |r| {
        if (r > 0) along += if (lab[r] > 0) @max(along_gap, lab[r] + label_room + trunk_room) else along_gap;
        starts[r] = along;
        along += thick[r];
    }
    // Across: each rank centered, in its order.
    const idx = try a.alloc(usize, n);
    for (idx, 0..) |*v, i| v.* = i;
    std.mem.sort(usize, idx, boxes, struct {
        fn lt(bs: []Box, x: usize, y: usize) bool {
            return if (bs[x].rank != bs[y].rank) bs[x].rank < bs[y].rank else bs[x].order < bs[y].order;
        }
    }.lt);
    const cursor = try a.alloc(f32, ranks);
    for (0..ranks) |r| cursor[r] = (widest - (span[r] - across_gap)) / 2;
    const pad: f32 = 12;
    for (idx) |i| {
        const b = &boxes[i];
        const across = if (vertical) b.w else b.h;
        const pos = starts[b.rank] + ((thick[b.rank] - (if (vertical) b.h else b.w)) / 2);
        const forward = dir == .down or dir == .right;
        b.r0 = pad + if (forward) starts[b.rank] else along - starts[b.rank] - thick[b.rank];
        b.r1 = b.r0 + thick[b.rank];
        b.lab = lab[b.rank];
        if (vertical) {
            b.x = pad + cursor[b.rank];
            b.y = pad + if (forward) pos else along - pos - b.h;
        } else {
            b.y = pad + cursor[b.rank];
            b.x = pad + if (forward) pos else along - pos - b.w;
        }
        cursor[b.rank] += across + across_gap;
    }
    // Room on the far side for edges that go back.
    var backs: f32 = 0;
    for (back) |is| if (is) {
        backs += 1;
    };
    const lanes = if (backs > 0) backs * 10 + 10 else 0;
    return .{
        (if (vertical) widest else along) + 2 * pad + (if (vertical) lanes else 0),
        (if (vertical) along else widest) + 2 * pad + (if (vertical) 0 else lanes),
    };
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

fn shape(c: *ui.Context, node: mm.Node, b: Box, k: f32) void {
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
    var st = label_style;
    st.size *= k;
    label(c, b.x, b.y, b.w, b.h, node.label, st);
}

/// From the source's side facing the target to the target's facing side:
/// out, across on the trunk, and in; the label on the way in.
fn forwardEdge(c: *ui.Context, pass: Pass, dir: mm.Dir, s: Box, t: Box, e: mm.Edge, ink: ui.Color, k: f32) void {
    const head = 8 * k;
    if (dir == .down or dir == .up) {
        const sx = s.x + s.w / 2;
        const tx = t.x + t.w / 2;
        const down = t.y > s.y;
        const sy = if (down) s.y + s.h else s.y;
        const ty = if (down) t.y else t.y + t.h;
        const mid = trunk(s, t, down, ty, k);
        if (pass == .labels) {
            if (e.label.len > 0) edgeLabel(c, tx, (mid + if (down) ty - head else ty + head) / 2, e.label, k);
            return;
        }
        line(c, sx, sy, sx, mid, e.line, ink);
        line(c, sx, mid, tx, mid, e.line, ink);
        line(c, tx, mid, tx, ty, e.line, ink);
        if (e.head) arrow(c, tx, ty, if (down) .down else .up, ink);
        if (e.tail) arrow(c, sx, sy, if (down) .up else .down, ink);
    } else {
        const sy = s.y + s.h / 2;
        const ty = t.y + t.h / 2;
        const right = t.x > s.x;
        const sx = if (right) s.x + s.w else s.x;
        const tx = if (right) t.x else t.x + t.w;
        const mid = trunk(s, t, right, tx, k);
        if (pass == .labels) {
            if (e.label.len > 0) edgeLabel(c, (mid + if (right) tx - head else tx + head) / 2, ty, e.label, k);
            return;
        }
        line(c, sx, sy, mid, sy, e.line, ink);
        line(c, mid, sy, mid, ty, e.line, ink);
        line(c, mid, ty, tx, ty, e.line, ink);
        if (e.head) arrow(c, tx, ty, if (right) .right else .left, ink);
        if (e.tail) arrow(c, sx, sy, if (right) .left else .right, ink);
    }
}

/// Where an edge crosses over to its target, along the flow: before a rank
/// with labels, far enough from it for them; between adjacent ranks, all
/// on one line midway across the gap; past a rank, just before the target
/// (`to`, its facing side), keeping to its column, not across the nodes
/// between.
fn trunk(s: Box, t: Box, forward: bool, to: f32, k: f32) f32 {
    if (t.lab > 0) return if (forward) t.r0 - t.lab - label_room * k else t.r1 + t.lab + label_room * k;
    if (t.rank == s.rank + 1) return gapMid(s, t, forward);
    return if (forward) to - 22 else to + 22;
}

/// The middle of the gap between a rank and the next, `forward` the way
/// the flow goes.
fn gapMid(s: Box, t: Box, forward: bool) f32 {
    return if (forward) (s.r1 + t.r0) / 2 else (s.r0 + t.r1) / 2;
}

/// Round the diagram's far side, back to an earlier node.
fn backEdge(c: *ui.Context, pass: Pass, dir: mm.Dir, s: Box, t: Box, e: mm.Edge, W: f32, H: f32, lane_k: f32, ink: ui.Color, k: f32) void {
    if (dir == .down or dir == .up) {
        const lane = W - 8 - (lane_k - 1) * 10;
        const sy = s.y + s.h / 2;
        const ty = t.y + t.h / 2;
        if (pass == .labels) {
            if (e.label.len > 0) edgeLabel(c, lane, (sy + ty) / 2, e.label, k);
            return;
        }
        line(c, s.x + s.w, sy, lane, sy, e.line, ink);
        line(c, lane, sy, lane, ty, e.line, ink);
        line(c, lane, ty, t.x + t.w, ty, e.line, ink);
        if (e.head) arrow(c, t.x + t.w, ty, .left, ink);
    } else {
        const lane = H - 8 - (lane_k - 1) * 10;
        const sx = s.x + s.w / 2;
        const tx = t.x + t.w / 2;
        if (pass == .labels) {
            if (e.label.len > 0) edgeLabel(c, (sx + tx) / 2, lane, e.label, k);
            return;
        }
        line(c, sx, s.y + s.h, sx, lane, e.line, ink);
        line(c, sx, lane, tx, lane, e.line, ink);
        line(c, tx, lane, tx, t.y + t.h, e.line, ink);
        if (e.head) arrow(c, tx, t.y + t.h, .up, ink);
    }
}

/// An edge's label on a patch of the background, centered at (x, y).
fn edgeLabel(c: *ui.Context, x: f32, y: f32, text: []const u8, k: f32) void {
    var st = small_style;
    st.size *= k;
    st.color = theme.muted;
    const sz = patch(measure(c, text, st));
    const w = sz[0];
    const h = sz[1];
    rect(c, x - w / 2, y - h / 2, w, h, theme.background, 4);
    label(c, x - w / 2, y - h / 2, w, h, text, st);
}

/// A label's size on its patch of background.
fn patch(sz: [2]f32) [2]f32 {
    return .{ sz[0] + 10, sz[1] + 4 };
}
