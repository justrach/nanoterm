//! Markdown drawn as a reader expects it: airy paragraphs in the text
//! font with bold, italics, inline code and links in place; headings;
//! lists with hanging markers and task boxes; quotes with a bar; tables
//! in a grid; code in a panel with its language, syntax colors and a
//! copy button; Mermaid diagrams drawn; and READMEs' HTML: centered
//! blocks, pictures (beside the file shown) and badges.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const md = @import("markdown.zig");
const highlight = @import("highlight.zig");

/// Prose: its size and line spacing.
pub const body: ui.TextStyle = .{ .size = 14, .leading = 1.5, .wrap = true };

fn palette() md.Palette {
    return .{ .code = theme.code_inline, .code_bg = theme.code_inline_bg, .link = theme.accent, .muted = theme.muted };
}

/// Draws the Markdown `src`.
pub fn markdown(c: *ui.Context, src: []const u8) void {
    markdownIn(c, src, null);
}

/// Where relative pictures are, while a file's Markdown is drawn.
var base: ?[]const u8 = null;

/// Draws the Markdown `src` of a file in folder `dir` (its pictures are
/// beside it).
pub fn markdownIn(c: *ui.Context, src: []const u8, dir: ?[]const u8) void {
    base = dir;
    defer base = null;
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

/// The picture `src` names, read from disk: an absolute path, `~/…`, or
/// beside the file shown; pictures on the web are not fetched.
fn picture(c: *ui.Context, src: []const u8) ?[]const u8 {
    const cache = pictures orelse return null;
    if (std.mem.indexOf(u8, src, "://") == null and !std.fs.path.isAbsolute(src) and !std.mem.startsWith(u8, src, "~/")) {
        const dir = base orelse return null;
        return cache.get(std.fs.path.join(c.alloc(), &.{ dir, src }) catch return null);
    }
    return cache.get(src);
}

/// Text, centered when HTML asked: a line that fits is drawn unwrapped,
/// as wide as it is, so it can be centered.
fn text(c: *ui.Context, in: md.Inline, style: ui.TextStyle) void {
    if (!in.center) return ui.richText(c, in.text, in.spans, style);
    const box = ui.div(c).column().wFull().itemsCenter();
    defer box.end();
    var st = style;
    const fits = std.mem.indexOfScalar(u8, in.text, '\n') == null and c.text.width(in.text, style) * 1.04 < c.size.w - 200;
    if (fits) st.wrap = false;
    ui.richText(c, in.text, in.spans, st);
}

fn rich(c: *ui.Context, in: md.Inline, style: ui.TextStyle) void {
    if (in.images.len == 0) return text(c, in, style);
    // Only pictures (a README's logo, a row of badges): a figure.
    var last: u32 = 0;
    var only = true;
    for (in.images) |im| {
        if (std.mem.trim(u8, in.text[last..@max(last, im.start)], " \t\n·|").len > 0) only = false;
        last = @max(last, im.end);
    }
    if (std.mem.trim(u8, in.text[last..], " \t\n·|").len > 0) only = false;
    if (only) return figures(c, in, style);
    // Text with pictures: the text, then the pictures that can be shown.
    const col = ui.div(c).column().wFull().gap(10);
    defer col.end();
    text(c, in, style);
    for (in.images, 0..) |im, i| {
        const bytes = picture(c, im.src) orelse continue;
        ui.key(c, c.print("pic-{d}", .{i}));
        figure(c, im, bytes, in.text[im.start..im.end], style, im.width == null and !in.center);
    }
}

/// A picture on the web: drawn at a pixel a point, as browsers draw it.
fn web(src: []const u8) bool {
    return std.mem.startsWith(u8, src, "https://") or std.mem.startsWith(u8, src, "http://");
}

/// A picture's size in points, from a PNG's header (else a guess), for
/// laying pictures out in rows.
fn sizeOf(im: md.Image, bytes: []const u8) f32 {
    const scale: f32 = if (web(im.src)) 1 else 2;
    var w: f32 = if (web(im.src)) 120 else 560;
    if (bytes.len >= 24 and std.mem.eql(u8, bytes[1..4], "PNG")) w = @as(f32, @floatFromInt(std.mem.readInt(u32, bytes[16..20], .big))) / scale;
    return @min(w, im.width orelse 560);
}

/// A picture, framed (a click opens it), with its alt text as a caption
/// when Markdown gave it (HTML's alt text describes, it isn't shown).
fn figure(c: *ui.Context, im: md.Image, bytes: []const u8, alt: []const u8, style: ui.TextStyle, caption: bool) void {
    const fig = ui.div(c).column().gap(6);
    defer fig.end();
    {
        // A badge from the web is drawn bare; a screenshot in a frame.
    var frame = ui.div(c).column();
    if (!web(im.src)) frame = frame.p(1).rounded(11).border(theme.border).bg(theme.panel);
        defer frame.end();
        if (frame.clicked()) {
            var buf: [4096]u8 = undefined;
            if (@import("pictures.zig").resolve(&buf, pictures.?.home, im.src)) |path| _ = nanoui.shell.openPath(path);
        }
        if (!ui.image(c, .{ .key = im.src, .bytes = bytes, .max_width = im.width orelse 560, .max_height = 420, .radius = if (web(im.src)) 0 else 10, .scale = if (web(im.src)) 1 else 2 })) ui.text(c, alt, style);
    }
    if (caption and alt.len > 0) ui.text(c, alt, .{ .size = 12, .color = theme.muted });
}

/// Pictures in rows (centered when asked): those that can be shown, and
/// the rest (a badge on the web) as a chip with their alt text.
fn figures(c: *ui.Context, in: md.Inline, style: ui.TextStyle) void {
    const col = ui.div(c).column().wFull().gap(6);
    const col2 = if (in.center) col.itemsCenter() else col;
    defer col2.end();
    const room = @max(200, c.size.w - 180);
    var i: usize = 0;
    while (i < in.images.len) {
        ui.key(c, c.print("figs-{d}", .{i}));
        const row = ui.div(c).row().gap(6).itemsCenter();
        defer row.end();
        var used: f32 = 0;
        while (i < in.images.len) : (i += 1) {
            const im = in.images[i];
            const alt = in.text[im.start..im.end];
            ui.key(c, c.print("fig-{d}", .{i}));
            if (picture(c, im.src)) |bytes| {
                const w = sizeOf(im, bytes);
                if (used > 0 and used + w > room) break;
                figure(c, im, bytes, alt, style, im.width == null and !in.center);
                used += w + 6;
            } else {
                const w = c.text.width(alt, .{ .size = 11.5 }) + 22;
                if (used > 0 and used + w > room) break;
                const chip = ui.div(c).row().px(9).py(3).rounded(6).bg(theme.code_inline_bg).border(theme.border);
                defer chip.end();
                ui.text(c, if (alt.len > 0) alt else std.fs.path.basename(im.src), .{ .size = 11.5, .color = theme.muted });
                used += w + 6;
            }
        }
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

fn codeBlock(c: *ui.Context, lang: []const u8, src: []const u8) void {
    const box = ui.div(c).column().wFull().p(1).bg(theme.code_bg).rounded(10).border(theme.border).clip();
    defer box.end();
    const mermaid = std.ascii.eqlIgnoreCase(lang, "mermaid");
    {
        const h = ui.div(c).row().wFull().px(12).py(6).gap(8).itemsCenter().bg(theme.code_header);
        defer h.end();
        if (mermaid) ui.icon(c, "point.3.connected.trianglepath.dotted", .{ .size = 11, .color = theme.muted });
        ui.text(c, if (mermaid) "mermaid diagram" else if (lang.len > 0) lang else "code", .{ .size = 11.5, .weight = .medium, .color = theme.muted });
        ui.spacer(c);
        if (ui.button(c, "Copy", .{ .variant = .ghost, .size = 11.5, .icon = "doc.on.doc" }).clicked) c.clipboard.write(c.clipboard.ctx, src);
    }
    if (mermaid) {
        const d = ui.div(c).column().wFull().p(14).bg(theme.background).clip();
        defer d.end();
        if (@import("view_mermaid.zig").diagram(c, src)) return;
        ui.text(c, "This kind of diagram shows as its source.", .{ .size = 11.5, .color = theme.muted });
    }
    const lines = ui.div(c).column().wFull().px(14).py(10).gap(0);
    defer lines.end();
    var in_block = false;
    var it = std.mem.splitScalar(u8, src, '\n');
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
