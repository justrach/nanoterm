//! Panes in Ghostty's manner: a binary tree of splits whose leaves are
//! sessions. ⌘D splits the focused pane to the right, ⌘⇧D below; closing a
//! pane gives its room to its sibling; panes resize, equalize, and are
//! found by direction from their rectangles. Pure data: the view lays it
//! out and draws it.
const std = @import("std");

pub const Axis = enum {
    /// Side by side: a vertical divider.
    horizontal,
    /// Stacked: a horizontal divider.
    vertical,
};

pub const Direction = enum { left, right, up, down };

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,
};

/// The room a divider takes between its panes.
pub const divider = 5;
const min_ratio = 0.1;

/// A node: a session (`leaf`, opaque to the tree) or a split of two nodes.
pub fn Tree(comptime Leaf: type) type {
    return struct {
        const Self = @This();

        pub const Node = struct {
            parent: ?*Node = null,
            kind: union(enum) {
                leaf: Leaf,
                split: struct { axis: Axis, ratio: f32 = 0.5, first: *Node, second: *Node },
            },
        };

        /// A leaf and where the view laid it out.
        pub const Placed = struct { node: *Node, rect: Rect };

        gpa: std.mem.Allocator,
        root: *Node,

        pub fn init(gpa: std.mem.Allocator, leaf: Leaf) !Self {
            const n = try gpa.create(Node);
            n.* = .{ .kind = .{ .leaf = leaf } };
            return .{ .gpa = gpa, .root = n };
        }

        pub fn deinit(t: *Self) void {
            t.free(t.root);
        }

        fn free(t: *Self, n: *Node) void {
            switch (n.kind) {
                .leaf => {},
                .split => |s| {
                    t.free(s.first);
                    t.free(s.second);
                },
            }
            t.gpa.destroy(n);
        }

        /// Splits `at` along `axis`; the new leaf goes after (right, below).
        pub fn split(t: *Self, at: *Node, axis: Axis, leaf: Leaf) !*Node {
            const old = try t.gpa.create(Node);
            errdefer t.gpa.destroy(old);
            const new = try t.gpa.create(Node);
            old.* = .{ .parent = at, .kind = at.kind };
            new.* = .{ .parent = at, .kind = .{ .leaf = leaf } };
            if (old.kind == .split) {
                old.kind.split.first.parent = old;
                old.kind.split.second.parent = old;
            }
            at.kind = .{ .split = .{ .axis = axis, .first = old, .second = new } };
            return new;
        }

        /// Removes leaf `n`; its sibling takes the parent's place. Returns
        /// the leaf that should take the focus, or null if `n` was the root.
        pub fn remove(t: *Self, n: *Node) ?*Node {
            const parent = n.parent orelse return null;
            const s = parent.kind.split;
            const sibling = if (s.first == n) s.second else s.first;
            // The sibling moves up into the parent's node.
            parent.kind = sibling.kind;
            if (parent.kind == .split) {
                parent.kind.split.first.parent = parent;
                parent.kind.split.second.parent = parent;
            }
            t.gpa.destroy(sibling);
            t.gpa.destroy(n);
            return t.firstLeaf(parent, n == s.first);
        }

        /// The first (or last) leaf under `n`.
        pub fn firstLeaf(_: *Self, n: *Node, last: bool) *Node {
            var cur = n;
            while (cur.kind == .split) cur = if (last) cur.kind.split.second else cur.kind.split.first;
            return cur;
        }

        /// The leaves in order (left to right, top to bottom).
        pub fn leaves(t: *Self, out: *std.ArrayList(*Node), arena: std.mem.Allocator) !void {
            try collect(t.root, out, arena);
        }

        fn collect(n: *Node, out: *std.ArrayList(*Node), arena: std.mem.Allocator) !void {
            switch (n.kind) {
                .leaf => try out.append(arena, n),
                .split => |s| {
                    try collect(s.first, out, arena);
                    try collect(s.second, out, arena);
                },
            }
        }

        pub fn count(n: *Node) usize {
            return switch (n.kind) {
                .leaf => 1,
                .split => |s| count(s.first) + count(s.second),
            };
        }

        /// Gives every leaf the same room (Ghostty's equalize_splits): a
        /// split's ratio is its first side's share of the leaves along it.
        pub fn equalize(n: *Node) void {
            switch (n.kind) {
                .leaf => {},
                .split => |*s| {
                    const a: f32 = @floatFromInt(weight(s.first, s.axis));
                    const b: f32 = @floatFromInt(weight(s.second, s.axis));
                    s.ratio = a / (a + b);
                    equalize(s.first);
                    equalize(s.second);
                },
            }
        }

        fn weight(n: *Node, axis: Axis) usize {
            return switch (n.kind) {
                .leaf => 1,
                .split => |s| if (s.axis == axis) weight(s.first, axis) + weight(s.second, axis) else @max(weight(s.first, axis), weight(s.second, axis)),
            };
        }

        /// Moves the divider nearest to `n` that lies in `dir` by `delta`
        /// of its split (Ghostty's resize_split). False if there is none.
        pub fn resize(n: *Node, dir: Direction, delta: f32) bool {
            const axis: Axis = if (dir == .left or dir == .right) .horizontal else .vertical;
            var cur = n.parent;
            while (cur) |p| : (cur = p.parent) {
                const s = &p.kind.split;
                if (s.axis != axis) continue;
                const grow = dir == .right or dir == .down;
                s.ratio = std.math.clamp(s.ratio + (if (grow) delta else -delta), min_ratio, 1 - min_ratio);
                return true;
            }
            return false;
        }

        /// The rectangles of `n`'s two sides and its divider within `r`.
        pub fn parts(s: anytype, r: Rect) [3]Rect {
            const d: f32 = divider;
            if (s.axis == .horizontal) {
                const w1 = @round((r.w - d) * s.ratio);
                return .{
                    .{ .x = r.x, .y = r.y, .w = w1, .h = r.h },
                    .{ .x = r.x + w1, .y = r.y, .w = d, .h = r.h },
                    .{ .x = r.x + w1 + d, .y = r.y, .w = r.w - w1 - d, .h = r.h },
                };
            }
            const h1 = @round((r.h - d) * s.ratio);
            return .{
                .{ .x = r.x, .y = r.y, .w = r.w, .h = h1 },
                .{ .x = r.x, .y = r.y + h1, .w = r.w, .h = d },
                .{ .x = r.x, .y = r.y + h1 + d, .w = r.w, .h = r.h - h1 - d },
            };
        }

        /// The leaf nearest `from` in `dir`, given each leaf's rectangle.
        pub fn neighbor(rects: []const Placed, from: Rect, dir: Direction) ?*Node {
            var best: ?*Node = null;
            var best_d: f32 = std.math.inf(f32);
            for (rects) |c| {
                const r = c.rect;
                const ok = switch (dir) {
                    .left => r.x + r.w <= from.x + 1 and overlap(r.y, r.h, from.y, from.h),
                    .right => r.x >= from.x + from.w - 1 and overlap(r.y, r.h, from.y, from.h),
                    .up => r.y + r.h <= from.y + 1 and overlap(r.x, r.w, from.x, from.w),
                    .down => r.y >= from.y + from.h - 1 and overlap(r.x, r.w, from.x, from.w),
                };
                if (!ok) continue;
                const dx = (r.x + r.w / 2) - (from.x + from.w / 2);
                const dy = (r.y + r.h / 2) - (from.y + from.h / 2);
                const d = dx * dx + dy * dy;
                if (d < best_d) {
                    best_d = d;
                    best = c.node;
                }
            }
            return best;
        }

        fn overlap(a: f32, al: f32, b: f32, bl: f32) bool {
            return a < b + bl - 1 and b < a + al - 1;
        }
    };
}

test "split, equalize, resize, remove" {
    const T = Tree(u32);
    var t = try T.init(std.testing.allocator, 1);
    defer t.deinit();
    const one = t.root;
    const two = try t.split(one, .horizontal, 2);
    // `one` is now the split; its first side holds leaf 1.
    const leaf1 = one.kind.split.first;
    const three = try t.split(two, .vertical, 3);
    try std.testing.expectEqual(@as(usize, 3), T.count(t.root));
    T.equalize(t.root);
    try std.testing.expectEqual(@as(f32, 0.5), t.root.kind.split.ratio);
    try std.testing.expect(T.resize(three, .left, 0.1));
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), t.root.kind.split.ratio, 0.001);
    // No split stacks leaf 1 with another: nothing moves up or down.
    try std.testing.expect(!T.resize(leaf1, .up, 0.1));
    // Removing leaf 3: leaf 2 takes the right side again.
    const focus = t.remove(three).?;
    try std.testing.expectEqual(@as(u32, 2), focus.kind.leaf);
    try std.testing.expectEqual(@as(usize, 2), T.count(t.root));
    const f2 = t.remove(leaf1).?;
    try std.testing.expectEqual(@as(u32, 2), f2.kind.leaf);
    try std.testing.expect(t.root.kind == .leaf);
    try std.testing.expect(t.remove(t.root) == null);
}

test "neighbors by direction" {
    const T = Tree(u32);
    var t = try T.init(std.testing.allocator, 1);
    defer t.deinit();
    const a = t.root;
    const b = try t.split(a, .horizontal, 2);
    const c = try t.split(b, .vertical, 3);
    const left = a.kind.split.first;
    const list = [_]T.Placed{
        .{ .node = left, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 200 } },
        .{ .node = b.kind.split.first, .rect = .{ .x = 105, .y = 0, .w = 100, .h = 100 } },
        .{ .node = c, .rect = .{ .x = 105, .y = 105, .w = 100, .h = 95 } },
    };
    try std.testing.expectEqual(left, T.neighbor(&list, list[2].rect, .left).?);
    try std.testing.expectEqual(b.kind.split.first, T.neighbor(&list, list[2].rect, .up).?);
    try std.testing.expect(T.neighbor(&list, list[0].rect, .left) == null);
}
