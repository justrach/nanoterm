//! The terminal's output, parsed: bytes from a pseudo-terminal become lines
//! of text with colored spans. It handles what command output uses (text,
//! carriage returns that redraw a line, backspace, tabs, erasing, SGR
//! colors in 16, 256 and 24-bit) and hands OSC sequences (the shell's block
//! marks, the working directory) to a callback. A full-screen program's
//! bytes, from the alternate screen on, drive a screen of cells instead
//! (`screen.zig`), until it leaves it. So does a program that draws in
//! place without it (Claude Code's prompts, Ink's apps, REPLs): one that
//! asks for the terminal's input (bracketed paste, focus, the mouse, the
//! kitty keyboard) gets a screen in the lines' place; the rows it scrolls
//! off stay lines, and what it showed last becomes lines when it ends.
const std = @import("std");
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;
const theme = @import("theme.zig");
const screen = @import("screen.zig");
const screen_vt = @import("screen_vt.zig");

pub const Line = struct {
    text: std.ArrayList(u8) = .empty,
    spans: std.ArrayList(nanoui.ui.Span) = .empty,

    fn deinit(l: *Line, gpa: std.mem.Allocator) void {
        l.text.deinit(gpa);
        l.spans.deinit(gpa);
    }

    /// Cuts the line at byte `at`, and its spans with it.
    fn truncate(l: *Line, at: usize) void {
        if (at >= l.text.items.len) return;
        l.text.shrinkRetainingCapacity(at);
        while (l.spans.items.len > 0) {
            const last = &l.spans.items[l.spans.items.len - 1];
            if (last.start >= at) {
                l.spans.items.len -= 1;
            } else {
                last.end = @min(last.end, @as(u32, @intCast(at)));
                break;
            }
        }
    }
};

pub const OscHandler = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, payload: []const u8) void,
};

const State = enum { ground, esc, csi, osc, osc_esc, charset };

/// At most this many lines are kept; older ones go.
pub const max_lines = 20_000;
/// Past `max_lines`, this many of the oldest go at once: one move of the
/// rest per batch, not one per line (which made long output quadratic).
const drop_batch = max_lines / 8;

/// Where a pseudo console's cursor is, by rows. Windows' ConPTY moves it to
/// a row (CSI H, CSI d) where Unix writes line breaks, and its rows count
/// from the console's top: one Cursor follows everything a shell writes,
/// whichever output it goes to.
pub const Cursor = struct {
    row: u32 = 0,
    rows: u32 = 24,
    /// The row the last line written is on: a move down makes lines past it.
    last: u32 = 0,

    fn down(cur: *Cursor, n: u32) void {
        cur.last = @min(cur.last + n, cur.rows -| 1);
        cur.row = cur.last;
    }
};

pub const Output = struct {
    gpa: std.mem.Allocator,
    /// The shell's cursor, where the console moves it by rows (Windows).
    cursor: ?*Cursor = null,
    lines: std.ArrayList(Line) = .empty,
    /// The cursor's byte offset in the last line.
    col: usize = 0,
    fg: ?Color = null,
    bold: bool = false,
    state: State = .ground,
    params: std.ArrayList(u8) = .empty,
    osc: std.ArrayList(u8) = .empty,
    osc_handler: ?OscHandler = null,
    /// A full-screen program switched to the alternate screen.
    alternate_screen: bool = false,
    /// Its screen, while it shows.
    full: ?*screen_vt.Vt = null,
    /// The terminal's size, for a full-screen program's screen.
    cols: u16 = 100,
    rows: u16 = 40,
    /// Where a full-screen program's questions are answered (its input).
    reply: ?screen.Reply = null,
    /// Lines dropped from the top for `max_lines`.
    dropped: usize = 0,
    /// A command's output (not the shell's between commands): a program
    /// drawing in place may take a screen.
    inline_ok: bool = false,
    /// The screen is such a program's, not the alternate screen.
    inline_screen: bool = false,

    pub fn init(gpa: std.mem.Allocator) Output {
        return .{ .gpa = gpa };
    }

    pub fn deinit(o: *Output) void {
        // Its screen goes first, kept nowhere.
        o.inline_screen = false;
        o.leaveScreen();
        for (o.lines.items) |*l| l.deinit(o.gpa);
        o.lines.deinit(o.gpa);
        o.params.deinit(o.gpa);
        o.osc.deinit(o.gpa);
    }

    /// The full-screen program's screen goes, as a terminal's alternate
    /// screen does when the program leaves it (or ends).
    pub fn leaveScreen(o: *Output) void {
        if (o.full) |f| {
            // What the alternate screen showed goes with it, as it does.
            if (o.inline_screen and !f.screen.done) o.keepScreen(f.screen);
            f.destroy();
        }
        o.full = null;
        o.alternate_screen = false;
        o.inline_screen = false;
    }

    /// A program drawing in place wants the terminal's input: its lines go
    /// onto a screen (the last screenful, cursor where it was), and it
    /// draws there, `trigger` (what asked) first.
    fn enterInline(o: *Output, trigger: []const u8) !void {
        if (!o.inline_ok or o.full != null) return;
        const v = try screen_vt.Vt.create(o.gpa, o.cols, o.rows);
        v.screen.reply = o.reply;
        v.screen.scrolled_off = .{ .ctx = o, .func = scrolledOff };
        o.full = v;
        o.inline_screen = true;
        const keep = @min(o.lines.items.len, @as(usize, o.rows) - 1);
        const first = o.lines.items.len - keep;
        var moved: std.ArrayList(Line) = .empty;
        defer {
            for (moved.items) |*l| l.deinit(o.gpa);
            moved.deinit(o.gpa);
        }
        try moved.appendSlice(o.gpa, o.lines.items[first..]);
        o.lines.shrinkRetainingCapacity(first);
        for (moved.items, 0..) |l, k| {
            _ = v.feed(l.text.items);
            if (k + 1 < moved.items.len) _ = v.feed("\r\n");
        }
        if (moved.items.len > 0 and o.col < moved.items[moved.items.len - 1].text.items.len) {
            var buf: [16]u8 = undefined;
            _ = v.feed("\r");
            if (o.col > 0) _ = v.feed(std.fmt.bufPrint(&buf, "\x1b[{d}C", .{o.col}) catch "");
        }
        _ = v.feed(trigger);
    }

    fn scrolledOff(ctx: *anyopaque, row: []const screen.Cell) void {
        const o: *Output = @ptrCast(@alignCast(ctx));
        o.appendRow(row) catch {};
    }

    /// A screen row as a line of the output: its text, colored by runs.
    fn appendRow(o: *Output, row: []const screen.Cell) !void {
        var end = row.len;
        while (end > 0 and (row[end - 1].cp == ' ' or row[end - 1].cp == 0)) end -= 1;
        o.trim();
        var l: Line = .{};
        errdefer l.deinit(o.gpa);
        for (row[0..end]) |cell| {
            if (cell.attrs.tail) continue;
            const start: u32 = @intCast(l.text.items.len);
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(if (cell.cp < 0x20) ' ' else cell.cp, &buf) catch 1;
            try l.text.appendSlice(o.gpa, buf[0..n]);
            if (cell.fg) |c| try addSpan(o.gpa, &l, .{ .start = start, .end = @intCast(l.text.items.len), .color = c });
        }
        try o.lines.append(o.gpa, l);
    }

    /// What the screen shows, down to its last row with text or the
    /// cursor, becomes lines; the next output starts a line of its own.
    fn keepScreen(o: *Output, s: *const screen.Screen) void {
        var last: usize = s.cur.y;
        for (0..s.rows) |y| for (s.row(y)) |cell| if (cell.cp != ' ' and cell.cp != 0) {
            last = @max(last, y);
            break;
        };
        for (0..last + 1) |y| o.appendRow(s.row(y)) catch {};
        o.lines.append(o.gpa, .{}) catch {};
        o.col = 0;
    }

    fn enterScreen(o: *Output) void {
        o.alternate_screen = true;
        if (o.full != null) return;
        o.full = screen_vt.Vt.create(o.gpa, o.cols, o.rows) catch return;
        o.full.?.screen.reply = o.reply;
    }

    /// The terminal changed size.
    pub fn resize(o: *Output, cols: u16, rows: u16) void {
        o.cols = cols;
        o.rows = rows;
        if (o.full) |f| f.screen.resize(cols, rows) catch {};
    }

    /// Keeps at least `max_lines`, at most `max_lines + drop_batch`.
    fn trim(o: *Output) void {
        if (o.lines.items.len < max_lines + drop_batch) return;
        for (o.lines.items[0..drop_batch]) |*l| l.deinit(o.gpa);
        const rest = o.lines.items[drop_batch..];
        std.mem.copyForwards(Line, o.lines.items[0..rest.len], rest);
        o.lines.items.len = rest.len;
        o.dropped += drop_batch;
    }

    fn current(o: *Output) !*Line {
        if (o.lines.items.len == 0) try o.lines.append(o.gpa, .{});
        return &o.lines.items[o.lines.items.len - 1];
    }

    fn newline(o: *Output) !void {
        o.trim();
        try o.lines.append(o.gpa, .{});
        o.col = 0;
        if (o.cursor) |cur| cur.down(1);
    }

    /// The console's cursor moved to `row`: past the last line's row, line
    /// breaks; above it, the lines already written are kept as they were.
    fn toRow(o: *Output, cur: *Cursor, row: u32) !void {
        const to = @min(row, cur.rows -| 1);
        if (to <= cur.last) {
            cur.row = to;
            return;
        }
        var n = to - cur.last;
        while (n > 0) : (n -= 1) try o.newline();
    }

    fn put(o: *Output, bytes: []const u8) !void {
        const l = try o.current();
        while (l.text.items.len < o.col) try l.text.append(o.gpa, ' ');
        const start = o.col;
        const end = start + bytes.len;
        // As a terminal does, writing after a carriage return overwrites
        // what is there; where that would split a multibyte character,
        // the rest of the line goes instead.
        if (start < l.text.items.len) {
            const over = @min(end, l.text.items.len);
            const ascii = for (l.text.items[start..over]) |c| {
                if (c >= 0x80) break false;
            } else true;
            const tail_ok = over == l.text.items.len or l.text.items[over] < 0x80 or (l.text.items[over] & 0xc0) != 0x80;
            if (ascii and tail_ok and isAscii(bytes)) {
                @memcpy(l.text.items[start..over], bytes[0 .. over - start]);
                try l.text.appendSlice(o.gpa, bytes[over - start ..]);
            } else {
                l.truncate(start);
                try l.text.appendSlice(o.gpa, bytes);
            }
            cutSpans(o.gpa, l, @intCast(start), @intCast(end));
        } else try l.text.appendSlice(o.gpa, bytes);
        o.col = end;
        // The console wrapped what goes past its width onto the next rows.
        if (o.cursor) |cur| if (o.cols > 0) {
            const before = if (start == 0) 0 else (start - 1) / o.cols;
            const after = if (end == 0) 0 else (end - 1) / o.cols;
            if (after > before) cur.down(@intCast(after - before));
        };
        const color = o.fg orelse if (o.bold) theme.ansi[15] else null;
        const c = color orelse return;
        try addSpan(o.gpa, l, .{ .start = @intCast(start), .end = @intCast(end), .color = c });
    }

    fn isAscii(bytes: []const u8) bool {
        for (bytes) |c| if (c >= 0x80) return false;
        return true;
    }

    /// Takes bytes [from, to) out of the line's spans.
    fn cutSpans(gpa: std.mem.Allocator, l: *Line, from: u32, to: u32) void {
        var i: usize = 0;
        while (i < l.spans.items.len) {
            const sp = l.spans.items[i];
            if (sp.end <= from or sp.start >= to) {
                i += 1;
            } else if (sp.start >= from and sp.end <= to) {
                _ = l.spans.orderedRemove(i);
            } else if (sp.start < from and sp.end > to) {
                // The cut is inside: split it in two.
                l.spans.items[i].end = from;
                l.spans.insert(gpa, i + 1, .{ .start = to, .end = sp.end, .color = sp.color }) catch {
                    l.spans.items[i].end = from;
                };
                i += 2;
            } else if (sp.start < from) {
                l.spans.items[i].end = from;
                i += 1;
            } else {
                l.spans.items[i].start = to;
                i += 1;
            }
        }
    }

    /// Adds a span in order, merging it with an equal neighbor.
    fn addSpan(gpa: std.mem.Allocator, l: *Line, span: nanoui.ui.Span) !void {
        var i: usize = l.spans.items.len;
        while (i > 0 and l.spans.items[i - 1].start >= span.end) i -= 1;
        if (i > 0) {
            const prev = &l.spans.items[i - 1];
            if (prev.end == span.start and std.meta.eql(prev.color, span.color)) {
                prev.end = span.end;
                return;
            }
        }
        try l.spans.insert(gpa, i, span);
    }

    /// Feeds bytes as they come from the pseudo-terminal.
    pub fn feed(o: *Output, bytes: []const u8) !void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (o.full) |f| {
                i += f.feed(bytes[i..]);
                if (f.screen.done) o.leaveScreen();
                continue;
            }
            const b = bytes[i];
            switch (o.state) {
                .ground => switch (b) {
                    0x1b => {
                        o.state = .esc;
                        i += 1;
                    },
                    '\n' => {
                        try o.newline();
                        i += 1;
                    },
                    '\r' => {
                        o.col = 0;
                        i += 1;
                    },
                    0x08 => {
                        if (o.col > 0) o.col -= 1;
                        i += 1;
                    },
                    '\t' => {
                        const n = 8 - (o.col % 8);
                        try o.put("        "[0..n]);
                        i += 1;
                    },
                    0x07, 0x00...0x06, 0x0b...0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => i += 1,
                    else => {
                        // A run of printable bytes (UTF-8 included).
                        var j = i;
                        while (j < bytes.len and bytes[j] >= 0x20 and bytes[j] != 0x7f) j += 1;
                        try o.put(bytes[i..j]);
                        i = j;
                    },
                },
                .esc => {
                    i += 1;
                    o.state = switch (b) {
                        '[' => blk: {
                            o.params.clearRetainingCapacity();
                            break :blk .csi;
                        },
                        ']' => blk: {
                            o.osc.clearRetainingCapacity();
                            break :blk .osc;
                        },
                        '(', ')', '*', '+' => .charset,
                        else => .ground,
                    };
                },
                .charset => {
                    i += 1;
                    o.state = .ground;
                },
                .csi => {
                    i += 1;
                    if (b >= 0x40 and b <= 0x7e) {
                        try o.csi(b);
                        o.state = .ground;
                    } else try o.params.append(o.gpa, b);
                },
                .osc => {
                    i += 1;
                    if (b == 0x07) {
                        o.endOsc();
                    } else if (b == 0x1b) {
                        o.state = .osc_esc;
                    } else try o.osc.append(o.gpa, b);
                },
                .osc_esc => {
                    i += 1;
                    o.endOsc();
                },
            }
        }
    }

    fn endOsc(o: *Output) void {
        o.state = .ground;
        if (o.osc_handler) |h| h.func(h.ctx, o.osc.items);
    }

    fn param(list: []const u8, index: usize, default: u32) u32 {
        var it = std.mem.splitScalar(u8, list, ';');
        var k: usize = 0;
        while (it.next()) |p| : (k += 1) {
            if (k == index) return if (p.len == 0) default else std.fmt.parseInt(u32, p, 10) catch default;
        }
        return default;
    }

    fn csi(o: *Output, final: u8) !void {
        const p = o.params.items;
        if (asksForInput(p, final)) {
            var buf: [64]u8 = undefined;
            const seq = std.fmt.bufPrint(&buf, "\x1b[{s}{c}", .{ p, final }) catch return;
            return o.enterInline(seq);
        }
        if (p.len > 0 and p[0] == '?') {
            // Private modes: the alternate screen marks a full-screen program.
            if (std.mem.eql(u8, p, "?1049") or std.mem.eql(u8, p, "?47") or std.mem.eql(u8, p, "?1047")) {
                if (final == 'h') o.enterScreen() else o.leaveScreen();
            }
            return;
        }
        switch (final) {
            'm' => o.sgr(p),
            'K' => {
                const l = try o.current();
                switch (param(p, 0, 0)) {
                    0 => l.truncate(o.col),
                    else => l.truncate(0),
                }
            },
            'C' => o.col += param(p, 0, 1),
            // Moves by rows, on a console that makes them (Windows).
            'H', 'f' => if (o.cursor) |cur| {
                try o.toRow(cur, param(p, 0, 1) -| 1);
                o.col = param(p, 1, 1) -| 1;
            },
            'd' => if (o.cursor) |cur| {
                const col = o.col;
                try o.toRow(cur, param(p, 0, 1) -| 1);
                o.col = col;
            },
            'B', 'E' => if (o.cursor) |cur| {
                const col = o.col;
                try o.toRow(cur, cur.row + param(p, 0, 1));
                if (final == 'B') o.col = col;
            },
            'D' => o.col -|= param(p, 0, 1),
            'G' => o.col = param(p, 0, 1) - 1,
            'J' => if (param(p, 0, 0) >= 2) {
                o.clear();
                if (o.cursor) |cur| cur.* = .{ .rows = cur.rows };
            },
            else => {},
        }
    }

    /// What a program that reads the terminal itself turns on: bracketed
    /// paste, focus reports, mouse tracking, the kitty keyboard.
    fn asksForInput(p: []const u8, final: u8) bool {
        if (final == 'u' and p.len > 0 and p[0] == '>') return true;
        if (final != 'h' or p.len == 0 or p[0] != '?') return false;
        var it = std.mem.splitScalar(u8, p[1..], ';');
        while (it.next()) |m| for ([_][]const u8{ "2004", "1004", "1000", "1002", "1003" }) |want| {
            if (std.mem.eql(u8, m, want)) return true;
        };
        return false;
    }

    pub fn clear(o: *Output) void {
        for (o.lines.items) |*l| l.deinit(o.gpa);
        o.lines.clearRetainingCapacity();
        o.col = 0;
    }

    fn sgr(o: *Output, p: []const u8) void {
        if (p.len == 0) {
            o.fg = null;
            o.bold = false;
            return;
        }
        var codes: [32]u32 = undefined;
        var n: usize = 0;
        var it = std.mem.tokenizeAny(u8, p, ";:");
        while (it.next()) |s| {
            if (n == codes.len) break;
            codes[n] = std.fmt.parseInt(u32, s, 10) catch 0;
            n += 1;
        }
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const c = codes[k];
            switch (c) {
                0 => {
                    o.fg = null;
                    o.bold = false;
                },
                1 => o.bold = true,
                22 => o.bold = false,
                30...37 => o.fg = theme.ansi[c - 30 + @as(u32, if (o.bold) 8 else 0)],
                39 => o.fg = null,
                90...97 => o.fg = theme.ansi[c - 90 + 8],
                38 => {
                    if (k + 2 < n and codes[k + 1] == 5) {
                        o.fg = theme.color256(@intCast(@min(codes[k + 2], 255)));
                        k += 2;
                    } else if (k + 4 < n and codes[k + 1] == 2) {
                        o.fg = .{
                            .r = @as(f32, @floatFromInt(@min(codes[k + 2], 255))) / 255,
                            .g = @as(f32, @floatFromInt(@min(codes[k + 3], 255))) / 255,
                            .b = @as(f32, @floatFromInt(@min(codes[k + 4], 255))) / 255,
                        };
                        k += 4;
                    }
                },
                48 => k += if (k + 1 < n and codes[k + 1] == 5) @as(usize, 2) else 4,
                else => {},
            }
        }
    }

    /// The output as plain text, lines joined by newlines.
    pub fn plainText(o: *const Output, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (o.lines.items, 0..) |l, i| {
            if (i > 0) try out.append(gpa, '\n');
            try out.appendSlice(gpa, l.text.items);
        }
        // A trailing empty line is the newline that ended the last.
        while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
        return out.toOwnedSlice(gpa);
    }

    /// The number of lines with text, not counting a final empty one.
    pub fn lineCount(o: *const Output) usize {
        var n = o.lines.items.len;
        while (n > 0 and o.lines.items[n - 1].text.items.len == 0) n -= 1;
        return n;
    }
};

test "long output drops its oldest lines a batch at a time, keeping the newest" {
    const gpa = std.testing.allocator;
    var o: Output = .init(gpa);
    defer o.deinit();
    var buf: [32]u8 = undefined;
    const n = max_lines + drop_batch + 10;
    for (0..n) |i| try o.feed(try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
    try std.testing.expect(o.lines.items.len >= max_lines and o.lines.items.len <= max_lines + drop_batch);
    try std.testing.expectEqual(n + 1, o.lines.items.len + o.dropped);
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "line {d}", .{n - 1}), o.lines.items[o.lines.items.len - 2].text.items);
}
