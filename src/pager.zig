//! Inside a block's output, as in a pager or a read-only Vim: a cursor
//! over the output's text, moved with the input's keys, selecting and
//! copying, searching. With Vim's keys, k in normal mode climbs from the
//! input into the output above, and j off its last line comes back down;
//! with Emacs's, M-v goes in. One is open at a time (`open`), in the pane
//! of its session; view_pager.zig draws it.
//!
//!   Vim    h j k l w b e W B E 0 ^ $ gg G H M L, ^D ^U ^F ^B ^E ^Y, zz zt zb,
//!          counts; / ? n N search; v V visual, o its other end; y yy Y copy;
//!          q Esc i a back to the input
//!   Emacs  C-n C-p C-f C-b M-f M-b C-a C-e M-< M-> C-v M-v; C-s C-r search;
//!          C-SPC the mark, M-w copy; C-g q back to the input
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Session = @import("session.zig").Session;
const blocks = @import("blocks.zig");

pub var open: ?*Pager = null;

pub const Visual = enum { none, char, line };

pub const Pager = struct {
    gpa: std.mem.Allocator,
    session: *Session,
    keys: ui.Keymap,
    title: []u8,
    /// The output's text, its last newlines left off (`buf` is all of it).
    buf: []u8,
    text: []const u8,
    /// Where each line starts in `text`.
    starts: std.ArrayList(usize) = .empty,
    /// The cursor (a byte in `text`), the column j and k keep, the first
    /// line shown and how many fit (from the last frame).
    at: usize = 0,
    want_col: usize = 0,
    top: usize = 0,
    rows: usize = 20,
    visual: Visual = .none,
    anchor: usize = 0,
    count: u32 = 0,
    pending: u8 = 0,
    /// The search being typed (after / ? C-s C-r), and the last one.
    prompt: ?std.ArrayList(u8) = null,
    back: bool = false,
    query: std.ArrayList(u8) = .empty,
    message: []const u8 = "",

    pub fn line(p: *const Pager, n: usize) []const u8 {
        const from = p.starts.items[n];
        const to = if (n + 1 < p.starts.items.len) p.starts.items[n + 1] - 1 else p.text.len;
        return p.text[from..to];
    }

    pub fn lineCount(p: *const Pager) usize {
        return p.starts.items.len;
    }

    pub fn rowOf(p: *const Pager, at: usize) usize {
        var lo: usize = 0;
        var hi = p.starts.items.len;
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (p.starts.items[mid] <= at) lo = mid else hi = mid;
        }
        return lo;
    }

    pub fn row(p: *const Pager) usize {
        return p.rowOf(p.at);
    }

    pub fn col(p: *const Pager) usize {
        return p.at - p.starts.items[p.row()];
    }

    /// The selection [from, to), or null outside visual mode / without a mark.
    pub fn selection(p: *const Pager) ?[2]usize {
        if (p.visual == .none) return null;
        var from = @min(p.anchor, p.at);
        var to = @max(p.anchor, p.at);
        if (p.visual == .line) {
            from = p.starts.items[p.rowOf(from)];
            const last = p.rowOf(to);
            to = p.starts.items[last] + p.line(last).len;
            return .{ from, @min(to + 1, p.text.len) };
        }
        // Vim's selection holds the character under the cursor; the mark's
        // region (Emacs) ends before it.
        return .{ from, if (p.keys == .vim) @min(to + 1, p.text.len) else to };
    }

    fn deinit(p: *Pager) void {
        p.gpa.free(p.title);
        p.gpa.free(p.buf);
        p.starts.deinit(p.gpa);
        p.query.deinit(p.gpa);
        if (p.prompt) |*q| q.deinit(p.gpa);
        p.gpa.destroy(p);
    }
};

/// The block the keys go into: the selected one, else the last with output.
pub fn target(s: *Session) ?*blocks.Block {
    var last: ?*blocks.Block = null;
    for (s.timeline.items) |e| switch (e) {
        .block => |b| {
            if (s.selected == b.id) return b;
            if (b.output.lineCount() > 0) last = b;
        },
        .turn => {},
    };
    return last;
}

/// Opens `b`'s output, the cursor on its last line (coming up from the input).
pub fn enter(s: *Session, b: *blocks.Block) void {
    close();
    const gpa = s.gpa;
    const p = gpa.create(Pager) catch return;
    const buf = b.output.plainText(gpa) catch {
        gpa.destroy(p);
        return;
    };
    // Last newlines make no lines of their own.
    const text = std.mem.trimEnd(u8, buf, "\n");
    const title = gpa.dupe(u8, b.command) catch {
        gpa.free(buf);
        gpa.destroy(p);
        return;
    };
    p.* = .{ .gpa = gpa, .session = s, .keys = s.shared.prefs.keys, .title = title, .buf = buf, .text = text };
    p.starts.append(gpa, 0) catch {};
    for (text, 0..) |ch, i| if (ch == '\n') p.starts.append(gpa, i + 1) catch {};
    p.at = p.starts.items[p.starts.items.len - 1];
    p.top = p.lineCount() -| p.rows;
    open = p;
}

pub fn close() void {
    if (open) |p| p.deinit();
    open = null;
}

/// Closed with its session (the tab went).
pub fn forget(s: *Session) void {
    if (open) |p| if (p.session == s) close();
}

// Moving.

fn class(ch: u8, big: bool) u2 {
    if (ch == ' ' or ch == '\t' or ch == '\n') return 0;
    if (big or std.ascii.isAlphanumeric(ch) or ch == '_' or ch >= 0x80) return 1;
    return 2;
}

fn wordForward(t: []const u8, i: usize, big: bool) usize {
    var j = i;
    if (j < t.len and class(t[j], big) != 0) {
        const k = class(t[j], big);
        while (j < t.len and class(t[j], big) == k) j += 1;
    }
    while (j < t.len and class(t[j], big) == 0) j += 1;
    return @min(j, t.len -| 1);
}

fn emacsWordEnd(t: []const u8, i: usize) usize {
    var j = i;
    while (j < t.len and class(t[j], false) != 1) j += 1;
    while (j < t.len and class(t[j], false) == 1) j += 1;
    return j;
}

fn wordEnd(t: []const u8, i: usize, big: bool) usize {
    if (t.len == 0) return 0;
    var j = @min(i + 1, t.len - 1);
    while (j < t.len - 1 and class(t[j], big) == 0) j += 1;
    const k = class(t[j], big);
    while (j + 1 < t.len and class(t[j + 1], big) == k) j += 1;
    return j;
}

fn wordBack(t: []const u8, i: usize, big: bool) usize {
    var j = i;
    while (j > 0 and class(t[j - 1], big) == 0) j -= 1;
    if (j == 0) return 0;
    const k = class(t[j - 1], big);
    while (j > 0 and class(t[j - 1], big) == k) j -= 1;
    return j;
}

/// To line `r`, at the column j and k keep.
fn toRow(p: *Pager, r: usize) void {
    const row_ = @min(r, p.lineCount() - 1);
    const l = p.line(row_);
    p.at = p.starts.items[row_] + @min(p.want_col, l.len -| 1);
}

fn toAt(p: *Pager, at: usize) void {
    p.at = @min(at, p.text.len -| 1);
    p.want_col = p.col();
}

/// Keeps the cursor in view; `place` puts its line at the top, middle or
/// bottom (zt zz zb).
fn scrollTo(p: *Pager, place: u8) void {
    const r = p.row();
    switch (place) {
        't' => p.top = r,
        'z' => p.top = r -| p.rows / 2,
        'b' => p.top = (r + 1) -| p.rows,
        else => {
            if (r < p.top) p.top = r;
            if (r >= p.top + p.rows) p.top = r + 1 - p.rows;
        },
    }
    p.top = @min(p.top, p.lineCount() -| p.rows);
}

fn search(p: *Pager, back: bool) void {
    const q = p.query.items;
    if (q.len == 0) return;
    const found = if (back)
        std.mem.lastIndexOf(u8, p.text[0..p.at], q) orelse std.mem.lastIndexOf(u8, p.text, q)
    else
        std.mem.indexOfPos(u8, p.text, @min(p.at + 1, p.text.len), q) orelse std.mem.indexOf(u8, p.text, q);
    if (found) |i| {
        toAt(p, i);
        p.message = "";
    } else p.message = "not found";
}

fn copy(c: *ui.Context, p: *Pager) void {
    const sel = p.selection() orelse return;
    const s = p.text[sel[0]..sel[1]];
    c.clipboard.write(c.clipboard.ctx, s);
    var lines: usize = 1;
    for (s) |ch| lines += @intFromBool(ch == '\n');
    p.message = if (p.visual == .line or lines > 1) "copied lines" else "copied";
    p.visual = .none;
    p.at = sel[0];
}

/// Back to the input.
fn leave(c: *ui.Context) void {
    close();
    c.changed = true;
}

// Keys.

/// The keys while it is open, in its session's pane.
pub fn keys(c: *ui.Context, p: *Pager) void {
    const S = ui.Shortcut;
    if (c.input.scroll.y != 0) {
        const by: isize = @intFromFloat(@round(-c.input.scroll.y / 18));
        p.top = @intCast(std.math.clamp(@as(isize, @intCast(p.top)) + by, 0, @as(isize, @intCast(p.lineCount() -| p.rows))));
        c.changed = true;
    }
    // A search being typed.
    if (p.prompt) |*q| {
        for (typed(c)) |ch| q.append(p.gpa, ch) catch {};
        var erase = c.input.key == .backspace;
        for (c.input.ops) |op| erase = erase or (op == .command and op.command == .delete_backward);
        if (erase and q.items.len > 0) q.items.len -= 1;
        if (c.shortcut(.{ .key = S.escape })) {
            q.deinit(p.gpa);
            p.prompt = null;
        } else if (c.shortcut(.{ .key = S.enter }) or c.input.key == .enter) {
            p.query.clearRetainingCapacity();
            p.query.appendSlice(p.gpa, q.items) catch {};
            q.deinit(p.gpa);
            p.prompt = null;
            search(p, p.back);
        }
        c.changed = true;
        return scrollTo(p, 0);
    }
    if (c.input.shortcut) |k| if (!k.cmd) {
        if (shortcut(c, p, k)) {
            c.shortcut_taken = true;
            c.input.shortcut = null;
            c.changed = true;
        }
    };
    if (open != p) return;
    for (typed(c)) |ch| {
        if (open != p) return;
        // After / or ? in the same event, the rest is the search.
        if (p.prompt) |*q| {
            q.append(p.gpa, ch) catch {};
            continue;
        }
        if (p.keys == .vim) vimKey(c, p, ch) else if (ch == 'q') return leave(c);
        c.changed = true;
    }
    if (open == p) scrollTo(p, 0);
}

/// What was typed in this event, as an input method or the Tester sends it.
fn typed(c: *ui.Context) []const u8 {
    var all: std.ArrayList(u8) = .empty;
    all.appendSlice(c.alloc(), c.input.chars) catch {};
    for (c.input.ops) |op| if (op == .insert) all.appendSlice(c.alloc(), op.insert) catch {};
    return all.items;
}

fn startSearch(p: *Pager, back: bool) void {
    p.prompt = .empty;
    p.back = back;
    p.message = "";
}

/// Keys with Control, Option, or none (arrows, Esc): true when taken.
fn shortcut(c: *ui.Context, p: *Pager, k: ui.Shortcut) bool {
    const S = ui.Shortcut;
    const t = p.text;
    const n = @max(p.count, 1);
    p.message = "";
    switch (k.key) {
        S.up => toRow(p, p.row() -| n),
        S.down => toRow(p, p.row() + n),
        S.left => toAt(p, p.at -| 1),
        S.right => toAt(p, p.at + 1),
        S.escape => {
            if (p.visual == .none and p.pending == 0 and p.count == 0) {
                leave(c);
                return true;
            }
            p.visual = .none;
            p.pending = 0;
            p.count = 0;
            return true;
        },
        else => {},
    }
    if (k.key == S.up or k.key == S.down or k.key == S.left or k.key == S.right) {
        p.count = 0;
        return true;
    }
    const half = @max(p.rows / 2, 1);
    if (k.ctrl and !k.alt) switch (k.key) {
        // Both editors' paging, and each one's own.
        'd' => toRow(p, p.row() + half),
        'u' => toRow(p, p.row() -| half),
        'f' => if (p.keys == .vim) toRow(p, p.row() + p.rows) else toAt(p, p.at + 1),
        'b' => if (p.keys == .vim) toRow(p, p.row() -| p.rows) else toAt(p, p.at -| 1),
        'e' => if (p.keys == .vim) {
            p.top = @min(p.top + 1, p.lineCount() -| p.rows);
            if (p.row() < p.top) toRow(p, p.top);
        } else toAt(p, p.starts.items[p.row()] + p.line(p.row()).len),
        'y' => if (p.keys == .vim) {
            p.top -|= 1;
            if (p.row() >= p.top + p.rows) toRow(p, p.top + p.rows - 1);
        } else return false,
        'n' => toRow(p, p.row() + n),
        'p' => toRow(p, p.row() -| n),
        'a' => toAt(p, p.starts.items[p.row()]),
        'v' => toRow(p, p.row() + p.rows),
        's' => startSearch(p, false),
        'r' => startSearch(p, true),
        ' ' => {
            p.visual = .char;
            p.anchor = p.at;
        },
        'g' => if (p.visual != .none) {
            p.visual = .none;
        } else {
            leave(c);
            return true;
        },
        else => return false,
    } else if (k.alt and !k.ctrl) switch (k.key) {
        // Emacs's words: to the end of this one, to the start of that one.
        'f' => toAt(p, emacsWordEnd(t, p.at)),
        'b' => toAt(p, wordBack(t, p.at, false)),
        'v' => toRow(p, p.row() -| p.rows),
        '<' => toAt(p, 0),
        '>' => toAt(p, t.len),
        ',' => if (k.shift) toAt(p, 0) else return false,
        '.' => if (k.shift) toAt(p, t.len) else return false,
        'w' => copy(c, p),
        else => return false,
    } else return false;
    p.count = 0;
    return true;
}

fn vimKey(c: *ui.Context, p: *Pager, ch: u8) void {
    const t = p.text;
    // A key waiting for this one: g (gg), y (yy), z (zz zt zb).
    if (p.pending != 0) {
        const was = p.pending;
        p.pending = 0;
        switch (was) {
            'g' => if (ch == 'g') toRow(p, if (p.count > 0) p.count - 1 else 0),
            'y' => if (ch == 'y') {
                p.visual = .line;
                p.anchor = p.at;
                toRow(p, p.row() + @max(p.count, 1) - 1);
                copy(c, p);
            },
            'z' => scrollTo(p, if (ch == '.') 'z' else ch),
            else => {},
        }
        p.count = 0;
        return;
    }
    if ((ch >= '1' and ch <= '9') or (ch == '0' and p.count > 0)) {
        p.count = @min(99999, p.count * 10 + (ch - '0'));
        return;
    }
    const n = @max(p.count, 1);
    p.message = "";
    const r = p.row();
    const ls = p.starts.items[r];
    switch (ch) {
        'h' => toAt(p, @max(ls, p.at -| n)),
        'l' => toAt(p, @min(ls + (p.line(r).len -| 1), p.at + n)),
        'j' => if (r + 1 >= p.lineCount() and p.visual == .none) return leave(c) else toRow(p, r + n),
        'k' => toRow(p, r -| n),
        'w', 'W' => for (0..n) |_| toAt(p, wordForward(t, p.at, ch == 'W')),
        'e', 'E' => for (0..n) |_| toAt(p, wordEnd(t, p.at, ch == 'E')),
        'b', 'B' => for (0..n) |_| toAt(p, wordBack(t, p.at, ch == 'B')),
        '0' => toAt(p, ls),
        '^' => {
            var j = ls;
            while (j < ls + p.line(r).len and (t[j] == ' ' or t[j] == '\t')) j += 1;
            toAt(p, j);
        },
        '$' => toAt(p, ls + (p.line(r).len -| 1)),
        'G' => toRow(p, if (p.count > 0) p.count - 1 else p.lineCount() - 1),
        'H' => toRow(p, p.top),
        'M' => toRow(p, p.top + @min(p.rows, p.lineCount() - p.top) / 2),
        'L' => toRow(p, p.top + @min(p.rows, p.lineCount() - p.top) -| 1),
        'g', 'z' => return {
            p.pending = ch;
        },
        'y' => if (p.visual != .none) copy(c, p) else return {
            p.pending = 'y';
        },
        'Y' => {
            p.visual = .line;
            p.anchor = p.at;
            toRow(p, r + n - 1);
            copy(c, p);
        },
        'v', 'V' => {
            const want: Visual = if (ch == 'v') .char else .line;
            if (p.visual == want) p.visual = .none else {
                if (p.visual == .none) p.anchor = p.at;
                p.visual = want;
            }
        },
        'o' => if (p.visual != .none) {
            const a = p.anchor;
            p.anchor = p.at;
            toAt(p, a);
        },
        '/', '?' => startSearch(p, ch == '?'),
        'n' => search(p, p.back),
        'N' => search(p, !p.back),
        'q', 'i', 'a', 'I', 'A' => return leave(c),
        else => {},
    }
    p.count = 0;
}
