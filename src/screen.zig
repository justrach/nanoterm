//! The screen of a full-screen program (vim, htop, less): a grid of
//! cells, each a character with its colors and attributes, a cursor, a
//! scrolling region and the modes programs set. `screen_vt.zig` parses the
//! bytes that drive it; the pane draws it (`view_screen.zig`).
const std = @import("std");
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;

pub const Attrs = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    inverse: bool = false,
    strike: bool = false,
    /// The right half of a wide character drawn in the cell before.
    tail: bool = false,
    _: u1 = 0,
};

pub const Cell = struct {
    cp: u21 = ' ',
    fg: ?Color = null,
    bg: ?Color = null,
    attrs: Attrs = .{},
};

/// Mouse reports a program asks for: presses and releases (9, 1000),
/// drags too (1002), every move (1003).
pub const Mouse = enum { off, press, drag, motion };

pub const Reply = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, bytes: []const u8) void,
};

/// Where rows scrolled off the screen's top go (a terminal's scrollback).
pub const ScrolledOff = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, row: []const Cell) void,
};

/// Columns a character takes: two for East Asian wide characters and
/// emoji, none for combining marks, one otherwise.
pub fn width(cp: u21) u2 {
    if (cp < 0x300) return 1;
    if ((cp >= 0x300 and cp <= 0x36f) or (cp >= 0x200b and cp <= 0x200f) or (cp >= 0xfe00 and cp <= 0xfe0f)) return 0;
    if ((cp >= 0x1100 and cp <= 0x115f) or (cp >= 0x2e80 and cp <= 0xa4cf) or (cp >= 0xac00 and cp <= 0xd7a3) or
        (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0xfe30 and cp <= 0xfe4f) or (cp >= 0xff00 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffe6) or (cp >= 0x1f300 and cp <= 0x1f64f) or (cp >= 0x1f900 and cp <= 0x1f9ff) or
        (cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

pub const Cursor = struct {
    x: u16 = 0,
    y: u16 = 0,
    pen: Cell = .{},
    origin: bool = false,
};

pub const Screen = struct {
    gpa: std.mem.Allocator,
    cols: u16,
    rows: u16,
    cells: []Cell,
    cur: Cursor = .{},
    saved: Cursor = .{},
    /// The last column was written: the next character wraps first.
    pending_wrap: bool = false,
    /// The scrolling region, rows top…bottom inclusive.
    top: u16 = 0,
    bottom: u16,
    tabs: std.DynamicBitSetUnmanaged = .{},
    // Modes.
    app_cursor: bool = false,
    cursor_visible: bool = true,
    autowrap: bool = true,
    insert: bool = false,
    bracketed_paste: bool = false,
    /// G0 and G1 hold DEC line drawing; shifted out uses G1.
    g0_lines: bool = false,
    g1_lines: bool = false,
    shift_out: bool = false,
    title: std.ArrayList(u8) = .empty,
    /// Where answers to the program's questions go (its input).
    reply: ?Reply = null,
    /// The program left the screen: the bytes after go to the blocks.
    done: bool = false,
    /// Points of wheel not yet sent as a line.
    wheel: f32 = 0,
    /// The mouse reports asked for, in SGR's form (1006) or the old one.
    mouse: Mouse = .off,
    mouse_sgr: bool = false,
    /// A press was reported and its release not yet; the cell last reported.
    mouse_held: bool = false,
    mouse_cell: [2]u16 = .{ 0xffff, 0xffff },
    /// Where the first cell was drawn, in the window, for the pointer.
    origin: ?[2]f32 = null,
    /// Text the program put on the clipboard (OSC 52), for the app to copy.
    copied: ?[]u8 = null,
    /// A program drawing in place of the lines (not on the alternate
    /// screen): rows leaving the top are kept here.
    scrolled_off: ?ScrolledOff = null,

    pub fn create(gpa: std.mem.Allocator, cols: u16, rows: u16) !*Screen {
        const s = try gpa.create(Screen);
        errdefer gpa.destroy(s);
        const c = @max(cols, 1);
        const r = @max(rows, 1);
        s.* = .{ .gpa = gpa, .cols = c, .rows = r, .cells = try gpa.alloc(Cell, @as(usize, c) * r), .bottom = r - 1 };
        @memset(s.cells, .{});
        try s.resetTabs();
        return s;
    }

    pub fn destroy(s: *Screen) void {
        s.gpa.free(s.cells);
        s.tabs.deinit(s.gpa);
        s.title.deinit(s.gpa);
        if (s.copied) |t| s.gpa.free(t);
        s.gpa.destroy(s);
    }

    fn resetTabs(s: *Screen) !void {
        try s.tabs.resize(s.gpa, s.cols, false);
        s.tabs.unsetAll();
        var x: usize = 8;
        while (x < s.cols) : (x += 8) s.tabs.set(x);
    }

    pub fn row(s: *const Screen, y: usize) []Cell {
        const w: usize = s.cols;
        return s.cells[y * w ..][0..w];
    }

    /// A cell blanked with the pen's background, as erasing does.
    fn blank(s: *const Screen) Cell {
        return .{ .bg = s.cur.pen.bg };
    }

    /// Keeps what fits, top left anchored, as xterm does.
    pub fn resize(s: *Screen, cols: u16, rows: u16) !void {
        const c = @max(cols, 1);
        const r = @max(rows, 1);
        if (c == s.cols and r == s.rows) return;
        const cells = try s.gpa.alloc(Cell, @as(usize, c) * r);
        @memset(cells, .{});
        // Rows that no longer fit go from the top, keeping the cursor's.
        const shift: usize = if (s.cur.y >= r) s.cur.y - r + 1 else 0;
        for (0..@min(r, s.rows - shift)) |y| {
            const from = s.row(y + shift);
            const n = @min(c, s.cols);
            @memcpy(cells[y * c ..][0..n], from[0..n]);
        }
        s.gpa.free(s.cells);
        s.cells = cells;
        s.cols = c;
        s.rows = r;
        s.top = 0;
        s.bottom = r - 1;
        s.cur.y = @intCast(@min(s.cur.y - shift, r - 1));
        s.cur.x = @min(s.cur.x, c - 1);
        s.pending_wrap = false;
        try s.resetTabs();
    }

    /// Writes one character at the cursor and moves past it.
    pub fn put(s: *Screen, cp_in: u21) void {
        var cp = cp_in;
        if ((if (s.shift_out) s.g1_lines else s.g0_lines) and cp >= 0x5f and cp <= 0x7e) cp = lineDrawing(cp);
        const w = width(cp);
        if (w == 0) return;
        if (s.pending_wrap) {
            s.pending_wrap = false;
            if (s.autowrap) {
                s.cur.x = 0;
                s.lineFeed();
            }
        }
        if (w == 2 and s.cur.x + 1 >= s.cols) {
            // A wide character does not split: it starts the next line.
            if (!s.autowrap) return;
            s.row(s.cur.y)[s.cur.x] = s.blank();
            s.cur.x = 0;
            s.lineFeed();
        }
        const r = s.row(s.cur.y);
        if (s.insert) {
            const x: usize = s.cur.x;
            std.mem.copyBackwards(Cell, r[x + w ..], r[x .. r.len - w]);
        }
        var cell = s.cur.pen;
        cell.cp = cp;
        cell.attrs.tail = false;
        r[s.cur.x] = cell;
        if (w == 2) {
            cell.cp = ' ';
            cell.attrs.tail = true;
            r[s.cur.x + 1] = cell;
        }
        if (s.cur.x + w >= s.cols) {
            s.cur.x = s.cols - 1;
            s.pending_wrap = true;
        } else s.cur.x += w;
    }

    /// Down a line, scrolling the region at its bottom.
    pub fn lineFeed(s: *Screen) void {
        if (s.cur.y == s.bottom) {
            s.scrollUp(1);
        } else if (s.cur.y + 1 < s.rows) s.cur.y += 1;
    }

    /// Up a line, scrolling the region down at its top.
    pub fn reverseIndex(s: *Screen) void {
        if (s.cur.y == s.top) {
            s.scrollDown(1);
        } else if (s.cur.y > 0) s.cur.y -= 1;
    }

    /// The region's rows move up `n`; blank rows enter at its bottom.
    pub fn scrollUp(s: *Screen, n_in: usize) void {
        s.shiftRows(s.top, n_in, true);
    }

    pub fn scrollDown(s: *Screen, n_in: usize) void {
        s.shiftRows(s.top, n_in, false);
    }

    /// Rows `from`…bottom move up (or down) `n_in`, blanks filling in.
    fn shiftRows(s: *Screen, from: u16, n_in: usize, up: bool) void {
        if (from > s.bottom) return;
        const span: usize = s.bottom - from + 1;
        const n = @min(n_in, span);
        const w: usize = s.cols;
        const region = s.cells[from * w .. (@as(usize, s.bottom) + 1) * w];
        if (up and from == 0) if (s.scrolled_off) |keep| for (0..n) |k| keep.func(keep.ctx, region[k * w ..][0..w]);
        if (up) {
            std.mem.copyForwards(Cell, region[0 .. (span - n) * w], region[n * w ..]);
            @memset(region[(span - n) * w ..], s.blank());
        } else {
            std.mem.copyBackwards(Cell, region[n * w ..], region[0 .. (span - n) * w]);
            @memset(region[0 .. n * w], s.blank());
        }
    }

    /// IL and DL: lines inserted or deleted at the cursor, in the region.
    pub fn insertLines(s: *Screen, n: usize) void {
        if (s.cur.y < s.top or s.cur.y > s.bottom) return;
        s.shiftRows(s.cur.y, n, false);
        s.cur.x = 0;
    }

    pub fn deleteLines(s: *Screen, n: usize) void {
        if (s.cur.y < s.top or s.cur.y > s.bottom) return;
        s.shiftRows(s.cur.y, n, true);
        s.cur.x = 0;
    }

    /// ICH and DCH: blanks inserted, or characters deleted, at the cursor.
    pub fn insertChars(s: *Screen, n_in: usize) void {
        const r = s.row(s.cur.y);
        const x: usize = s.cur.x;
        const n = @min(n_in, r.len - x);
        std.mem.copyBackwards(Cell, r[x + n ..], r[x .. r.len - n]);
        @memset(r[x .. x + n], s.blank());
    }

    pub fn deleteChars(s: *Screen, n_in: usize) void {
        const r = s.row(s.cur.y);
        const x: usize = s.cur.x;
        const n = @min(n_in, r.len - x);
        std.mem.copyForwards(Cell, r[x .. r.len - n], r[x + n ..]);
        @memset(r[r.len - n ..], s.blank());
    }

    /// ECH: `n` characters at the cursor blanked.
    pub fn eraseChars(s: *Screen, n: usize) void {
        const r = s.row(s.cur.y);
        const x: usize = s.cur.x;
        @memset(r[x..@min(r.len, x + @max(n, 1))], s.blank());
    }

    /// EL: 0 to the end of the line, 1 from its start, 2 all of it.
    pub fn eraseLine(s: *Screen, how: u32) void {
        const r = s.row(s.cur.y);
        const x: usize = s.cur.x;
        switch (how) {
            0 => @memset(r[x..], s.blank()),
            1 => @memset(r[0..@min(r.len, x + 1)], s.blank()),
            else => @memset(r, s.blank()),
        }
        s.pending_wrap = false;
    }

    /// ED: 0 to the end of the screen, 1 from its start, 2 and 3 all.
    pub fn eraseDisplay(s: *Screen, how: u32) void {
        const at = @as(usize, s.cur.y) * s.cols + s.cur.x;
        switch (how) {
            0 => @memset(s.cells[at..], s.blank()),
            1 => @memset(s.cells[0..@min(s.cells.len, at + 1)], s.blank()),
            else => @memset(s.cells, s.blank()),
        }
    }

    /// CUP: to row `y`, column `x` (from 0), within the region in origin mode.
    pub fn moveTo(s: *Screen, x: usize, y: usize) void {
        const base: usize = if (s.cur.origin) s.top else 0;
        const limit: usize = if (s.cur.origin) s.bottom else s.rows - 1;
        s.cur.y = @intCast(@min(base + y, limit));
        s.cur.x = @intCast(@min(x, s.cols - 1));
        s.pending_wrap = false;
    }

    /// Relative moves that stop at the region's edges, as CUU and CUD do.
    pub fn moveBy(s: *Screen, dx: i32, dy: i32) void {
        const top: i32 = if (s.cur.y >= s.top) s.top else 0;
        const bottom: i32 = if (s.cur.y <= s.bottom) s.bottom else s.rows - 1;
        const y = std.math.clamp(@as(i32, s.cur.y) + dy, top, bottom);
        const x = std.math.clamp(@as(i32, s.cur.x) + dx, 0, @as(i32, s.cols) - 1);
        s.cur.x = @intCast(x);
        s.cur.y = @intCast(y);
        s.pending_wrap = false;
    }

    /// DECSTBM: the scrolling region; the cursor goes home.
    pub fn setRegion(s: *Screen, top: usize, bottom: usize) void {
        const b = @min(if (bottom == 0) s.rows else bottom, s.rows) - 1;
        const t = if (top == 0) 0 else top - 1;
        if (t >= b) return;
        s.top = @intCast(t);
        s.bottom = @intCast(b);
        s.moveTo(0, 0);
    }

    pub fn tab(s: *Screen) void {
        var x: usize = s.cur.x + 1;
        while (x < s.cols and !s.tabs.isSet(x)) x += 1;
        s.cur.x = @intCast(@min(x, s.cols - 1));
    }

    pub fn save(s: *Screen) void {
        s.saved = s.cur;
    }

    pub fn restore(s: *Screen) void {
        s.cur = s.saved;
        s.cur.x = @min(s.cur.x, s.cols - 1);
        s.cur.y = @min(s.cur.y, s.rows - 1);
        s.pending_wrap = false;
    }

    /// A row's characters as UTF-8 (wide characters' tails left out), in
    /// `arena`, with where each column starts in the bytes.
    pub fn rowText(s: *const Screen, arena: std.mem.Allocator, y: usize, starts: []u32) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.ensureTotalCapacity(arena, s.cols) catch return "";
        for (s.row(y), 0..) |cell, x| {
            starts[x] = @intCast(out.items.len);
            if (cell.attrs.tail) continue;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(if (cell.cp < 0x20) ' ' else cell.cp, &buf) catch 1;
            out.appendSlice(arena, buf[0..n]) catch {};
        }
        starts[s.cols] = @intCast(out.items.len);
        return out.items;
    }
};

/// DEC special graphics: the line-drawing set programs switch to.
fn lineDrawing(cp: u21) u21 {
    const map = [_]u21{
        ' ', '◆', '▒', '␉', '␌', '␍', '␊', '°', '±', '␤', '␋', '┘', '┐', '┌', '└', '┼',
        '⎺', '⎻', '─', '⎼', '⎽', '├', '┤', '┴', '┬', '│', '≤', '≥', 'π', '≠', '£', '·',
    };
    return map[cp - 0x5f];
}

test "writing, wrapping, scrolling a region, wide characters" {
    const gpa = std.testing.allocator;
    const s = try Screen.create(gpa, 4, 3);
    defer s.destroy();
    for ("abcdef") |ch| s.put(ch);
    try std.testing.expectEqual(@as(u21, 'a'), s.row(0)[0].cp);
    try std.testing.expectEqual(@as(u21, 'e'), s.row(1)[0].cp);
    try std.testing.expectEqual(@as(u16, 2), s.cur.x);
    s.moveTo(0, 2);
    s.lineFeed();
    // At the bottom: everything moved up a row.
    try std.testing.expectEqual(@as(u21, 'e'), s.row(0)[0].cp);
    s.setRegion(2, 3);
    s.moveTo(0, 1);
    s.put('X');
    s.moveTo(0, 2);
    s.lineFeed();
    try std.testing.expectEqual(@as(u21, 'e'), s.row(0)[0].cp);
    try std.testing.expectEqual(@as(u21, ' '), s.row(2)[0].cp);
    s.setRegion(0, 0);
    s.moveTo(0, 0);
    s.deleteChars(1);
    try std.testing.expectEqual(@as(u21, 'f'), s.row(0)[0].cp);
    s.moveTo(3, 2);
    s.put(0x4e2d);
    // A wide character at the last column starts the next line.
    try std.testing.expectEqual(@as(u21, 0x4e2d), s.row(2)[0].cp);
    try std.testing.expect(s.row(2)[1].attrs.tail);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var starts: [5]u32 = undefined;
    const t = s.rowText(arena.allocator(), 2, &starts);
    try std.testing.expectEqualStrings("中  ", t);
    try s.resize(6, 2);
    try std.testing.expectEqual(@as(u16, 1), s.cur.y);
    try std.testing.expectEqual(@as(u21, 0x4e2d), s.row(1)[0].cp);
}
