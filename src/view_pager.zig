//! Inside a block's output (pager.zig): its lines in the terminal's font,
//! the selection and the cursor over them, the lines that fit from the
//! first shown; and a status line as Vim has one: the mode, the search
//! being typed or what was done, where the cursor is.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const pager = @import("pager.zig");

const header_h: f32 = 40;
const status_h: f32 = 34;

pub fn draw(c: *ui.Context, p: *pager.Pager, w: f32, h: f32) void {
    const style: ui.TextStyle = .{ .size = 13, .mono = true, .color = theme.text };
    const lh = @ceil(c.text.lineHeight(style) * 1.25);
    const box = ui.div(c).column().w(w).h(h).bg(theme.background);
    defer box.end();
    {
        const r = ui.div(c).row().wFull().h(header_h).px(16).gap(8).itemsCenter().bg(theme.panel);
        defer r.end();
        ui.text(c, "❯", .{ .size = 13, .weight = .bold, .mono = true, .color = theme.accent });
        ui.text(c, p.title, .{ .size = 13, .mono = true, .color = theme.text });
        ui.spacer(c);
        ui.text(c, c.print("{d} lines", .{p.lineCount()}), .{ .size = 11.5, .color = theme.muted });
    }
    const body_h = @max(lh, h - header_h - status_h);
    p.rows = @max(1, @as(usize, @intFromFloat(@floor((body_h - 12) / lh))));
    {
        const body = ui.div(c).column().wFull().h(body_h).px(16).pt(6).clip();
        defer body.end();
        const sel = p.selection();
        const cur = p.row();
        const last = @min(p.top + p.rows, p.lineCount());
        for (p.top..last) |row| {
            const l = p.line(row);
            const from = p.starts.items[row];
            ui.key(c, c.print("pl-{d}", .{row}));
            const r = ui.div(c).row().wFull().h(lh).itemsCenter();
            defer r.end();
            if (sel) |s| if (s[0] <= from + l.len and s[1] > from) {
                const a = @max(s[0], from) - from;
                const b = @min(s[1], from + l.len) - from;
                const x0 = c.text.width(l[0..a], style);
                // A selection past the line's end holds its newline: a space more.
                var x1 = c.text.width(l[0..b], style);
                if (s[1] > from + l.len) x1 += c.text.width(" ", style);
                _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x0, .y = 0 }, .width = .{ .px = @max(x1 - x0, 2) }, .height = .{ .px = lh }, .background = theme.accent.alpha(0.22) }, .none, null);
            };
            if (row == cur) {
                const col = @min(p.col(), l.len);
                const x = c.text.width(l[0..col], style);
                const cw = if (col < l.len) c.text.width(l[col .. col + 1], style) else c.text.width("m", style);
                // Vim's block over the character; Emacs's bar before it.
                const vim = p.keys == .vim;
                _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = 0 }, .width = .{ .px = if (vim) cw else 2 }, .height = .{ .px = lh }, .background = if (vim) theme.accent.alpha(0.45) else theme.accent }, .none, null);
            }
            ui.text(c, if (l.len == 0) " " else l, style);
        }
    }
    status(c, p);
}

fn status(c: *ui.Context, p: *pager.Pager) void {
    const r = ui.div(c).row().wFull().h(status_h).px(16).gap(10).itemsCenter().bg(theme.panel);
    defer r.end();
    const vim = p.keys == .vim;
    const mode: []const u8 = if (vim) switch (p.visual) {
        .none => "NORMAL",
        .char => "VISUAL",
        .line => "V-LINE",
    } else if (p.visual != .none) "MARK" else "EMACS";
    {
        const d = ui.div(c).row().px(8).py(3).rounded(6).bg(theme.accent.alpha(0.16));
        defer d.end();
        ui.text(c, mode, .{ .size = 10.5, .weight = .bold, .mono = true, .color = theme.accent });
    }
    if (p.prompt) |q| {
        ui.text(c, c.print("{s}{s}▏", .{ if (!vim) "search: " else if (p.back) "?" else "/", q.items }), .{ .size = 12.5, .mono = true, .color = theme.text });
    } else if (p.message.len > 0) {
        ui.text(c, p.message, .{ .size = 12, .color = theme.muted });
    } else {
        const hint = if (vim) "q back · / search · v select · y copy" else "C-g back · C-s search · C-SPC mark · M-w copy";
        ui.text(c, hint, .{ .size = 11.5, .color = theme.faint });
    }
    ui.spacer(c);
    const total = p.lineCount();
    const row = p.row() + 1;
    ui.text(c, c.print("{d}:{d}  {d}%", .{ row, p.col() + 1, row * 100 / @max(total, 1) }), .{ .size = 11.5, .mono = true, .color = theme.muted });
}
