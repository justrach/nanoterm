//! Find (⌘F): the focused pane's commands and output searched as typed,
//! case-insensitively; every match highlighted, the current one brighter,
//! and the timeline scrolled to it as ↩ and ⇧↩ step through.
const std = @import("std");
const nanoui = @import("nanoui");
const Span = nanoui.ui.Span;
const Color = nanoui.ui.Color;
const blocks = @import("blocks.zig");
const theme = @import("theme.zig");

/// A match: in a block's output line (or its command, line `command`),
/// bytes [start, end).
pub const Match = struct { block: u64, line: usize, start: u32, end: u32 };
pub const command = std.math.maxInt(usize);

/// What the view shares with the blocks it draws, for one frame.
pub const State = struct {
    /// The pane searched (its session's id).
    session: u64 = 0,
    query: []const u8 = "",
    matches: []const Match = &.{},
    current: usize = 0,
    /// The block of the current match, to scroll to once.
    scroll_to: ?u64 = null,
    /// Where that block was in the last frame (window points).
    target_y: ?f32 = null,

    pub fn active(f: *const State) bool {
        return f.query.len > 0;
    }

    pub fn currentMatch(f: *const State) ?Match {
        if (f.matches.len == 0) return null;
        return f.matches[@min(f.current, f.matches.len - 1)];
    }
};

pub fn highlight() Color {
    return theme.warning.alpha(0.28);
}
pub fn highlight_current() Color {
    return theme.warning.alpha(0.75);
}

fn eqlFold(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}

/// Each place `query` is in `text`.
fn each(arena: std.mem.Allocator, out: *std.ArrayList(Match), text: []const u8, query: []const u8, block: u64, line: usize) void {
    if (query.len == 0 or text.len < query.len) return;
    var i: usize = 0;
    while (i + query.len <= text.len) {
        if (eqlFold(text[i .. i + query.len], query)) {
            out.append(arena, .{ .block = block, .line = line, .start = @intCast(i), .end = @intCast(i + query.len) }) catch return;
            i += query.len;
        } else i += 1;
    }
}

/// The matches in the blocks of `timeline`, in order.
pub fn collect(arena: std.mem.Allocator, items: anytype, query: []const u8) []const Match {
    var out: std.ArrayList(Match) = .empty;
    for (items) |entry| switch (entry) {
        .block => |b| {
            each(arena, &out, b.command, query, b.id, command);
            for (b.output.lines.items, 0..) |l, i| each(arena, &out, l.text.items, query, b.id, i);
        },
        .turn => {},
    };
    return out.items;
}

/// `spans` with the matches of line `line` of block `block` highlighted
/// (backgrounds, in order of where they start).
pub fn spansFor(arena: std.mem.Allocator, f: *const State, spans: []const Span, block: u64, line: usize) []const Span {
    if (!f.active() or f.matches.len == 0) return spans;
    const cur = f.currentMatch();
    var out: std.ArrayList(Span) = .empty;
    var added = false;
    for (f.matches) |m| {
        if (m.block != block or m.line != line) continue;
        const is_current = if (cur) |c| std.meta.eql(c, m) else false;
        out.append(arena, .{ .start = m.start, .end = m.end, .background = if (is_current) highlight_current() else highlight(), .color = if (is_current) theme.background else null }) catch break;
        added = true;
    }
    if (!added) return spans;
    out.appendSlice(arena, spans) catch {};
    std.mem.sort(Span, out.items, {}, struct {
        fn lt(_: void, a: Span, b: Span) bool {
            return a.start < b.start;
        }
    }.lt);
    return out.items;
}

test "matches, ignoring case, and their highlights" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(Match) = .empty;
    each(a, &out, "Error: no error here, ERROR", "error", 7, 0);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqual(@as(u32, 10), out.items[1].start);
    const f: State = .{ .query = "error", .matches = out.items, .current = 1 };
    const spans = spansFor(a, &f, &.{.{ .start = 0, .end = 5, .color = theme.failure }}, 7, 0);
    try std.testing.expectEqual(@as(usize, 4), spans.len);
    try std.testing.expectEqual(highlight_current(), spans[2].background.?);
}
