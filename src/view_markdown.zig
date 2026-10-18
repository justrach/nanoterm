//! Markdown drawn as a reader expects it: airy paragraphs in the text
//! font with bold, italics, inline code and links in place; headings;
//! lists with hanging markers and task boxes; quotes with a bar; tables
//! in a grid; code in a panel with its language, syntax colors and a
//! copy button.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const md = @import("markdown.zig");
const highlight = @import("highlight.zig");

/// Prose: its size and line spacing.
pub const body: ui.TextStyle = .{ .size = 14, .leading = 1.5, .wrap = true };

fn palette() md.Palette {
    return .{ .code = theme.code_inline, .code_bg = theme.code_inline_bg, .link = theme.accent };
}

/// Draws the Markdown `src`.
pub fn markdown(c: *ui.Context, src: []const u8) void {
    const blocks = md.parse(c.alloc(), src, palette());
    const col = ui.div(c).column().wFull();
    defer col.end();
    for (blocks, 0..) |b, i| {
        // Items of a list sit close; other blocks get room.
        if (i > 0) {
            const tight = b == .item and blocks[i - 1] == .item;
            _ = c.leaf(.{ .height = .{ .px = if (tight) 3 else 12 } }, .none, null);
        }
        ui.key(c, c.print("md-{d}", .{i}));
        block(c, b, i == 0);
    }
}

/// Where answers' pictures come from (the window's cache; none in tests
/// that don't set it).
pub var pictures: ?*@import("pictures.zig").Cache = null;

fn rich(c: *ui.Context, in: md.Inline, style: ui.TextStyle) void {
    if (in.images.len == 0) return ui.richText(c, in.text, in.spans, style);
    // The text, unless it is only the pictures' alt text; then the pictures.
    var shown: [8]?[]const u8 = @splat(null);
    const n = @min(in.images.len, shown.len);
    var only_alts = true;
    var last: u32 = 0;
    for (in.images[0..n], 0..) |im, i| {
        if (pictures) |cache| shown[i] = cache.get(im.src);
        if (std.mem.trim(u8, in.text[last..im.start], " \t").len > 0) only_alts = false;
        if (shown[i] == null) only_alts = false;
        last = im.end;
    }
    if (std.mem.trim(u8, in.text[last..], " \t").len > 0) only_alts = false;
    const col = ui.div(c).column().wFull().gap(10);
    defer col.end();
    if (!only_alts) ui.richText(c, in.text, in.spans, style);
    for (in.images[0..n], 0..) |im, i| {
        const bytes = shown[i] orelse continue;
        ui.key(c, c.print("pic-{d}", .{i}));
        const fig = ui.div(c).column().gap(6);
        defer fig.end();
        {
            const frame = ui.div(c).column().p(1).rounded(11).border(theme.border).bg(theme.panel);
            defer frame.end();
            if (frame.clicked()) {
                var buf: [4096]u8 = undefined;
                if (@import("pictures.zig").resolve(&buf, pictures.?.home, im.src)) |path| _ = nanoui.shell.openPath(path);
            }
            if (!ui.image(c, .{ .key = im.src, .bytes = bytes, .max_width = 560, .max_height = 420, .radius = 10 })) {
                ui.text(c, in.text[im.start..im.end], style);
            }
        }
        if (im.end > im.start) ui.text(c, in.text[im.start..im.end], .{ .size = 12, .color = theme.muted });
    }
}

fn block(c: *ui.Context, b: md.Block, first: bool) void {
    switch (b) {
        .paragraph => |in| rich(c, in, body),
        .heading => |h| {
            if (!first) _ = c.leaf(.{ .height = .{ .px = if (h.level <= 2) 6 else 2 } }, .none, null);
            const size: f32 = switch (h.level) {
                1 => 19,
                2 => 16.5,
                3 => 15,
                else => 14,
            };
            var st = body;
            st.size = size;
            st.leading = 1.3;
            st.weight = if (h.level <= 2) .bold else .semibold;
            rich(c, h.text, st);
            if (h.level == 1) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = theme.border }, .none, null);
        },
        .item => |it| item(c, it),
        .quote => |in| {
            const r = ui.div(c).row().wFull().gap(12);
            defer r.end();
            _ = c.leaf(.{ .width = .{ .px = 3 }, .height = .fill, .radius = 1.5, .background = theme.agent.alpha(0.45) }, .none, null);
            var st = body;
            st.color = theme.muted;
            st.italic = true;
            const box = ui.div(c).column().grow();
            defer box.end();
            rich(c, in, st);
        },
        .rule => _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = theme.border }, .none, null),
        .code => |code| codeBlock(c, code.lang, code.text),
        .table => |t| table(c, t.header, t.rows),
    }
}

fn item(c: *ui.Context, it: @FieldType(md.Block, "item")) void {
    const r = ui.div(c).row().wFull().gap(8).pl(@as(f32, @floatFromInt(it.depth)) * 20);
    defer r.end();
    {
        // The marker's column: a fixed width, so wrapped lines hang.
        const m = ui.div(c).row().w(if (it.marker.len > 2) 26 else 16).h(c.text.lineHeight(body)).itemsCenter();
        defer m.end();
        if (it.task) |done| {
            ui.icon(c, if (done) "checkmark.circle.fill" else "circle", .{ .size = 13, .color = if (done) theme.success else theme.muted });
        } else if (std.mem.eql(u8, it.marker, "•")) {
            _ = c.leaf(.{ .width = .{ .px = 5 }, .height = .{ .px = 5 }, .radius = 2.5, .background = theme.muted, .offset = .{ .x = 4 } }, .none, null);
        } else {
            ui.text(c, it.marker, .{ .size = 13, .color = theme.muted });
        }
    }
    const box = ui.div(c).column().grow();
    defer box.end();
    var st = body;
    if (it.task == true) st.color = theme.muted;
    rich(c, it.text, st);
}

fn syntax() highlight.Palette {
    return .{
        .keyword = theme.syn_keyword,
        .string = theme.syn_string,
        .number = theme.syn_number,
        .comment = theme.syn_comment,
        .type = theme.syn_type,
        .call = theme.syn_call,
    };
}

fn codeBlock(c: *ui.Context, lang: []const u8, text: []const u8) void {
    const box = ui.div(c).column().wFull().p(1).bg(theme.code_bg).rounded(10).border(theme.border).clip();
    defer box.end();
    {
        const h = ui.div(c).row().wFull().px(12).py(6).gap(8).itemsCenter().bg(theme.code_header);
        defer h.end();
        ui.text(c, if (lang.len > 0) lang else "code", .{ .size = 11.5, .weight = .medium, .color = theme.muted });
        ui.spacer(c);
        if (ui.button(c, "Copy", .{ .variant = .ghost, .size = 11.5, .icon = "doc.on.doc" }).clicked) c.clipboard.write(c.clipboard.ctx, text);
    }
    const lines = ui.div(c).column().wFull().px(14).py(10).gap(0);
    defer lines.end();
    var in_block = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        const spans = highlight.line(c.alloc(), l, lang, syntax(), &in_block);
        ui.richText(c, if (l.len == 0) " " else l, spans, .{ .size = 12.5, .mono = true, .wrap = true, .leading = 1.35, .color = theme.text });
    }
}

fn table(c: *ui.Context, header: []const md.Inline, rows: []const []const md.Inline) void {
    const box = ui.div(c).column().wFull().p(1).rounded(8).border(theme.border).clip();
    defer box.end();
    tableRow(c, header, true, false);
    for (rows, 0..) |r, i| tableRow(c, r, false, i % 2 == 1);
}

fn tableRow(c: *ui.Context, cells: []const md.Inline, head: bool, zebra: bool) void {
    var r = ui.div(c).row().wFull();
    if (head) r = r.bg(theme.code_header) else if (zebra) r = r.bg(theme.block_hover);
    defer r.end();
    for (cells) |cell| {
        const d = ui.div(c).column().wFull().px(10).py(6);
        defer d.end();
        var st = body;
        st.size = 13;
        st.leading = 1.35;
        if (head) st.weight = .semibold;
        rich(c, cell, st);
    }
}
