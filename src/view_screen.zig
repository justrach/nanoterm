//! A full-screen program's screen, drawn over its whole pane as a
//! terminal draws it: each row a line of monospaced text with its colors
//! and attributes, backgrounds as runs of cells, the cursor as a block.
//! Keys go to the program as a terminal sends them; the mouse too, when
//! it asks (`screen_mouse.zig`), else its text selects as output's does.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const screen = @import("screen.zig");
const Screen = screen.Screen;
const Session = @import("session.zig").Session;
const mouse = @import("screen_mouse.zig");

/// The size of the text; blocks show output at the same.
pub fn style() ui.TextStyle {
    return .{ .size = 12.5, .mono = true, .color = theme.text };
}
pub const pad_x = 20;
pub const pad_y = 10;

pub const Metrics = struct { w: f32, h: f32 };

/// A cell's width and height in the monospaced font.
pub fn metrics(c: *ui.Context) Metrics {
    return .{ .w = c.text.width("M", style()), .h = @ceil(c.text.lineHeight(style())) };
}

/// The terminal's columns and rows in a pane `w` × `h` points.
pub fn fit(c: *ui.Context, w: f32, h: f32) [2]u16 {
    const m = metrics(c);
    return .{
        @intFromFloat(std.math.clamp((w - 2 * pad_x) / m.w, 20, 1000)),
        @intFromFloat(std.math.clamp((h - 2 * pad_y) / m.h, 5, 500)),
    };
}

const Look = struct {
    fg: ui.Color,
    bg: ?ui.Color,
    a: screen.Attrs,
};

/// What a cell looks like: inverse swaps its colors, dim fades them.
fn look(cell: screen.Cell) Look {
    var fg = cell.fg orelse theme.text;
    var bg = cell.bg;
    if (cell.attrs.inverse) {
        const was = fg;
        fg = bg orelse theme.background;
        bg = was;
    }
    if (cell.attrs.dim) fg = fg.alpha(0.6);
    var a = cell.attrs;
    a.inverse = false;
    a.dim = false;
    a.tail = false;
    return .{ .fg = fg, .bg = bg, .a = a };
}

pub fn draw(c: *ui.Context, s: *Screen, focused: bool) void {
    const m = metrics(c);
    const box = c.open(.{
        .direction = .column,
        .width = .fill,
        .grow = 1,
        .background = theme.background,
        .padding = .{ .left = pad_x, .right = pad_x, .top = pad_y, .bottom = pad_y },
        .clip = true,
        // Its text selects unless the program has the pointer.
        .selectable = !mouse.tracking(c, s),
    }, null);
    defer c.end();
    // Where its cells were drawn last frame, for the pointer's reports.
    if (c.rects.get(c.node(box).id)) |r| s.origin = .{ r.x + pad_x, r.y + pad_y };
    const starts = c.alloc().alloc(u32, @as(usize, s.cols) + 1) catch return;
    for (0..s.rows) |y| backgrounds(c, s, y, m);
    for (0..s.rows) |y| {
        const text = s.rowText(c.alloc(), y, starts);
        const r = ui.div(c).row().wFull().h(m.h).itemsCenter();
        defer r.end();
        ui.richText(c, text, spans(c, s.row(y), starts), style());
    }
    if (s.cursor_visible) {
        const color = if (focused) theme.accent.alpha(0.75) else theme.muted.alpha(0.5);
        _ = c.leaf(.{
            .absolute = true,
            .offset = .{ .x = @as(f32, @floatFromInt(s.cur.x)) * m.w, .y = @as(f32, @floatFromInt(s.cur.y)) * m.h },
            .width = .{ .px = m.w },
            .height = .{ .px = m.h },
            .background = if (focused) color else null,
            .border = if (focused) null else color,
            .border_width = 1,
        }, .none, null);
    }
}

/// A row's backgrounds, one box per run of cells of a color.
fn backgrounds(c: *ui.Context, s: *Screen, y: usize, m: Metrics) void {
    const cells = s.row(y);
    var x: usize = 0;
    while (x < cells.len) {
        const bg = look(cells[x]).bg orelse {
            x += 1;
            continue;
        };
        var end = x + 1;
        while (end < cells.len) : (end += 1) {
            const next = look(cells[end]).bg orelse break;
            if (!std.meta.eql(next, bg)) break;
        }
        _ = c.leaf(.{
            .absolute = true,
            .offset = .{ .x = @as(f32, @floatFromInt(x)) * m.w, .y = @as(f32, @floatFromInt(y)) * m.h },
            .width = .{ .px = @as(f32, @floatFromInt(end - x)) * m.w },
            .height = .{ .px = m.h },
            .background = bg,
        }, .none, null);
        x = end;
    }
}

/// Spans for a row's colors and attributes (byte offsets from `starts`).
fn spans(c: *ui.Context, cells: []const screen.Cell, starts: []const u32) []const ui.Span {
    var out: std.ArrayList(ui.Span) = .empty;
    var x: usize = 0;
    while (x < cells.len) {
        const l = look(cells[x]);
        var end = x + 1;
        while (end < cells.len) : (end += 1) {
            const n = look(cells[end]);
            if (!std.meta.eql(n.fg, l.fg) or n.a != l.a) break;
        }
        const plain = std.meta.eql(l.fg, theme.text) and !l.a.bold and !l.a.italic and !l.a.underline and !l.a.strike;
        if (!plain) out.append(c.alloc(), .{
            .start = starts[x],
            .end = starts[end],
            .color = l.fg,
            .weight = if (l.a.bold) .bold else null,
            .italic = l.a.italic,
            .underline = l.a.underline,
            .strike = l.a.strike,
        }) catch {};
        x = end;
    }
    return out.items;
}

/// Keys for the program, as xterm sends them; ⌘ combinations stay the
/// app's. Takes them from this frame's input.
pub fn keys(c: *ui.Context, a: *Session, s: *Screen) void {
    var buf: [16]u8 = undefined;
    mouse.pointer(c, a, s);
    wheel(c, a, s);
    // What the program copied (its own selection), onto the clipboard.
    if (s.copied) |text| {
        c.clipboard.write(c.clipboard.ctx, text);
        s.gpa.free(text);
        s.copied = null;
    }
    // Pasted text, marked as pasted when the program asked (vim, zsh).
    for (c.input.ops) |op| if (op == .insert) {
        if (s.bracketed_paste) a.shell.input("\x1b[200~");
        a.shell.input(op.insert);
        if (s.bracketed_paste) a.shell.input("\x1b[201~");
        c.changed = true;
    };
    if (c.input.shortcut) |k| if (!k.cmd) {
        c.shortcut_taken = true;
        c.input.shortcut = null;
        c.changed = true;
        const S = ui.Shortcut;
        const bytes: []const u8 = switch (k.key) {
            S.up => arrow(&buf, s, 'A'),
            S.down => arrow(&buf, s, 'B'),
            S.left => arrow(&buf, s, 'D'),
            S.right => arrow(&buf, s, 'C'),
            S.escape => "\x1b",
            S.tab => if (k.shift) "\x1b[Z" else "\t",
            ' ', '@', '2' => if (k.ctrl) "\x00" else "",
            '[' => if (k.ctrl) "\x1b" else "",
            '\\' => if (k.ctrl) "\x1c" else "",
            ']' => if (k.ctrl) "\x1d" else "",
            'a'...'z' => blk: {
                if (!k.ctrl) break :blk "";
                buf[0] = @intCast(k.key - 'a' + 1);
                break :blk buf[0..1];
            },
            else => "",
        };
        if (bytes.len > 0) a.shell.input(bytes);
        return;
    };
    if (c.input.chars.len > 0) {
        a.shell.input(c.input.chars);
        c.changed = true;
    }
    const k = c.input.key orelse return;
    c.changed = true;
    a.shell.input(switch (k) {
        .enter => "\r",
        .backspace => "\x7f",
        .tab => "\t",
        .escape => "\x1b",
        .up => arrow(&buf, s, 'A'),
        .down => arrow(&buf, s, 'B'),
        .right => arrow(&buf, s, 'C'),
        .left => arrow(&buf, s, 'D'),
        .home => if (s.app_cursor) "\x1bOH" else "\x1b[H",
        .end => if (s.app_cursor) "\x1bOF" else "\x1b[F",
        .delete => "\x1b[3~",
        .page_up => "\x1b[5~",
        .page_down => "\x1b[6~",
        .f1 => "\x1bOP",
        .f2 => "\x1bOQ",
        .f3 => "\x1bOR",
        .f4 => "\x1bOS",
        .f5 => "\x1b[15~",
        .f6 => "\x1b[17~",
        .f7 => "\x1b[18~",
        .f8 => "\x1b[19~",
        .f9 => "\x1b[20~",
        .f10 => "\x1b[21~",
        .f11 => "\x1b[23~",
        .f12 => "\x1b[24~",
    });
}

/// The wheel, a line a row's height: the program's wheel buttons when it
/// tracks the mouse, else the arrow keys, as terminals do.
fn wheel(c: *ui.Context, a: *Session, s: *Screen) void {
    c.wants_wheel = true;
    const dy = c.input.scroll.y;
    if (dy == 0) return;
    const m = metrics(c);
    s.wheel += dy;
    var buf: [4]u8 = undefined;
    while (@abs(s.wheel) >= m.h) {
        const up = s.wheel > 0;
        if (mouse.tracking(c, s)) mouse.wheel(c, a, s, up) else a.shell.input(arrow(&buf, s, if (up) 'A' else 'B'));
        s.wheel -= if (up) m.h else -m.h;
    }
}

/// Cursor keys: SS3 in application mode (vim, less), CSI otherwise.
fn arrow(buf: []u8, s: *const Screen, final: u8) []const u8 {
    buf[0] = 0x1b;
    buf[1] = if (s.app_cursor) 'O' else '[';
    buf[2] = final;
    return buf[0..3];
}
