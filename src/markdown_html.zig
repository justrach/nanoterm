//! The HTML READMEs mix into Markdown, as GitHub shows it: paragraphs and
//! headings (centered with `align="center"`), pictures with their width,
//! links, bold, italics, code, small print (`<sub>`, `<small>`), line
//! breaks, `<details>` with its summary; comments and the rest left out.
//! Each HTML block becomes Markdown blocks; text inside keeps its spans.
const std = @import("std");
const md = @import("markdown.zig");
const Block = md.Block;
const Builder = md.Parser.Builder;
const Flags = md.Parser.Flags;

/// Tags that start an HTML block (CommonMark's kinds 2 and 6, as READMEs
/// use them), or a comment.
const block_tags = [_][]const u8{ "p", "div", "center", "h1", "h2", "h3", "h4", "h5", "h6", "img", "picture", "details", "summary", "table", "br", "hr", "a", "section", "figure" };

/// Whether a line starts an HTML block.
pub fn starts(t: []const u8) bool {
    if (std.mem.startsWith(u8, t, "<!--")) return true;
    const tag = parseTag(t) orelse return false;
    for (block_tags) |name| if (std.ascii.eqlIgnoreCase(tag.name, name)) return true;
    return false;
}

/// An inline tag within Markdown text: its length, and whether it breaks
/// the line (`<br>`); the others (`<kbd>`, `<sub>`, `<b>`…) are left out.
pub fn inlineTag(s: []const u8) ?struct { len: usize, br: bool } {
    const tag = parseTag(s) orelse return null;
    const known = [_][]const u8{ "br", "b", "strong", "i", "em", "kbd", "sub", "sup", "small", "span", "code", "u", "mark", "a", "img", "ins", "del", "s" };
    for (known) |name| if (std.ascii.eqlIgnoreCase(tag.name, name)) return .{ .len = tag.len, .br = std.ascii.eqlIgnoreCase(name, "br") };
    return null;
}

const Tag = struct {
    name: []const u8,
    attrs: []const u8,
    closing: bool,
    /// The tag's bytes, `<` to `>`.
    len: usize,
};

/// The tag at the start of `s` (`<name attrs>`, `</name>`, `<name/>`).
fn parseTag(s: []const u8) ?Tag {
    if (s.len < 3 or s[0] != '<') return null;
    var i: usize = 1;
    const closing = s[i] == '/';
    if (closing) i += 1;
    const name_start = i;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-')) i += 1;
    if (i == name_start or !std.ascii.isAlphabetic(s[name_start])) return null;
    const name = s[name_start..i];
    // To the `>` outside quotes.
    var quote: u8 = 0;
    const attrs_start = i;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '>') {
            return .{ .name = name, .attrs = std.mem.trim(u8, s[attrs_start..i], " \t\n/"), .closing = closing, .len = i + 1 };
        }
    }
    return null;
}

/// Attribute `name`'s value in `attrs` (quoted or bare), if it is there.
fn attr(attrs: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and (attrs[i] == ' ' or attrs[i] == '\t' or attrs[i] == '\n')) i += 1;
        const start = i;
        while (i < attrs.len and attrs[i] != '=' and attrs[i] != ' ' and attrs[i] != '\t' and attrs[i] != '\n') i += 1;
        const key = attrs[start..i];
        if (i >= attrs.len or attrs[i] != '=') {
            if (i == start) i += 1;
            continue;
        }
        i += 1;
        var value: []const u8 = "";
        if (i < attrs.len and (attrs[i] == '"' or attrs[i] == '\'')) {
            const q = attrs[i];
            const end = std.mem.indexOfScalarPos(u8, attrs, i + 1, q) orelse attrs.len;
            value = attrs[i + 1 .. end];
            i = @min(end + 1, attrs.len);
        } else {
            const vs = i;
            while (i < attrs.len and attrs[i] != ' ' and attrs[i] != '\t') i += 1;
            value = attrs[vs..i];
        }
        if (std.ascii.eqlIgnoreCase(key, name)) return value;
    }
    return null;
}

const Converter = struct {
    arena: std.mem.Allocator,
    pal: md.Palette,
    out: *std.ArrayList(Block),
    b: Builder,
    flags: Flags = .{},
    center: bool = false,
    level: u8 = 0,
    /// Nesting of the marks, so a closing tag undoes its own.
    bold: u8 = 0,
    italic: u8 = 0,
    code: u8 = 0,
    link: u8 = 0,
    muted: u8 = 0,

    fn fresh(c: *Converter) void {
        c.b = .{ .arena = c.arena, .pal = c.pal };
    }

    fn marks(c: *Converter) Flags {
        return .{ .bold = c.bold > 0 or c.level > 0, .italic = c.italic > 0, .code = c.code > 0, .link = c.link > 0, .muted = c.muted > 0 };
    }

    /// Text, its runs of spaces made one, none at a block's start.
    fn text(c: *Converter, raw: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        try decode(c.arena, raw, &buf);
        var out: std.ArrayList(u8) = .empty;
        var space = c.b.text.items.len == 0 or c.b.text.items[c.b.text.items.len - 1] == ' ' or c.b.text.items[c.b.text.items.len - 1] == '\n';
        for (buf.items) |ch| {
            const ws = ch == ' ' or ch == '\n' or ch == '\t' or ch == '\r';
            if (ws) {
                if (!space) try out.append(c.arena, ' ');
                space = true;
            } else {
                try out.append(c.arena, ch);
                space = false;
            }
        }
        try c.b.emit(out.items, c.marks());
    }

    /// The block gathered so far, if it has text or pictures.
    fn flush(c: *Converter) !void {
        var t = c.b.text.items;
        while (t.len > 0 and (t[t.len - 1] == ' ' or t[t.len - 1] == '\n')) t.len -= 1;
        if (t.len > 0 or c.b.images.items.len > 0) {
            for (c.b.spans.items) |*sp| sp.end = @min(sp.end, @as(u32, @intCast(t.len)));
            const in: md.Inline = .{ .text = t, .spans = c.b.spans.items, .images = c.b.images.items, .center = c.center };
            try c.out.append(c.arena, if (c.level > 0) .{ .heading = .{ .level = c.level, .text = in } } else .{ .paragraph = in });
        }
        c.fresh();
    }

    fn tag(c: *Converter, t: Tag) !void {
        const n = t.name;
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(n, "p") or eq(n, "div") or eq(n, "center") or eq(n, "section") or eq(n, "figure") or eq(n, "details") or eq(n, "table") or eq(n, "tr")) {
            try c.flush();
            if (!t.closing) {
                const al = attr(t.attrs, "align") orelse "";
                c.center = eq(n, "center") or eq(al, "center");
            } else c.center = false;
        } else if (n.len == 2 and (n[0] == 'h' or n[0] == 'H') and n[1] >= '1' and n[1] <= '6') {
            try c.flush();
            c.level = if (t.closing) 0 else n[1] - '0';
            c.center = !t.closing and eq(attr(t.attrs, "align") orelse "", "center");
        } else if (eq(n, "summary")) {
            try c.flush();
            c.bold = if (t.closing) 0 else 1;
        } else if (eq(n, "hr")) {
            try c.flush();
            try c.out.append(c.arena, .rule);
        } else if (eq(n, "br")) {
            try c.b.emit("\n", c.marks());
        } else if (eq(n, "img")) {
            const src = attr(t.attrs, "src") orelse return;
            const alt = attr(t.attrs, "alt") orelse "";
            const width: ?f32 = if (attr(t.attrs, "width")) |w| std.fmt.parseFloat(f32, std.mem.trimEnd(u8, w, "px")) catch null else null;
            const start: u32 = @intCast(c.b.text.items.len);
            var buf: std.ArrayList(u8) = .empty;
            try decode(c.arena, alt, &buf);
            var f = c.marks();
            f.link = true;
            try c.b.emit(buf.items, f);
            try c.b.images.append(c.arena, .{ .src = src, .start = start, .end = @intCast(c.b.text.items.len), .width = width });
        } else {
            const counter: ?*u8 = if (eq(n, "b") or eq(n, "strong")) &c.bold else if (eq(n, "i") or eq(n, "em")) &c.italic else if (eq(n, "code") or eq(n, "kbd") or eq(n, "tt")) &c.code else if (eq(n, "a")) &c.link else if (eq(n, "sub") or eq(n, "sup") or eq(n, "small")) &c.muted else null;
            const k = counter orelse return;
            if (t.closing) k.* -|= 1 else k.* += 1;
        }
    }
};

/// The blocks of HTML `src`, appended to `out`.
pub fn convert(arena: std.mem.Allocator, pal: md.Palette, src: []const u8, out: *std.ArrayList(Block)) !void {
    var c: Converter = .{ .arena = arena, .pal = pal, .out = out, .b = undefined };
    c.fresh();
    var i: usize = 0;
    var plain: usize = 0;
    while (i < src.len) {
        if (std.mem.startsWith(u8, src[i..], "<!--")) {
            try c.text(src[plain..i]);
            const end = std.mem.indexOfPos(u8, src, i + 4, "-->") orelse src.len;
            i = @min(end + 3, src.len);
            plain = i;
            continue;
        }
        if (src[i] == '<') if (parseTag(src[i..])) |t| {
            try c.text(src[plain..i]);
            try c.tag(t);
            i += t.len;
            plain = i;
            continue;
        };
        i += 1;
    }
    try c.text(src[plain..]);
    try c.flush();
}

/// HTML's character references, the common named ones and numeric ones.
fn decode(arena: std.mem.Allocator, s: []const u8, out: *std.ArrayList(u8)) !void {
    const names = [_]struct { []const u8, []const u8 }{
        .{ "amp", "&" },     .{ "lt", "<" },       .{ "gt", ">" },     .{ "quot", "\"" },  .{ "apos", "'" },
        .{ "nbsp", " " },    .{ "middot", "·" },   .{ "mdash", "—" },  .{ "ndash", "–" },  .{ "hellip", "…" },
        .{ "copy", "©" },    .{ "reg", "®" },      .{ "trade", "™" },  .{ "rarr", "→" },   .{ "larr", "←" },
        .{ "bull", "•" },    .{ "times", "×" },
    };
    var i: usize = 0;
    outer: while (i < s.len) {
        if (s[i] == '&') if (std.mem.indexOfScalarPos(u8, s, i + 1, ';')) |semi| if (semi - i <= 10) {
            const ref = s[i + 1 .. semi];
            if (ref.len > 1 and ref[0] == '#') {
                const cp = if (ref[1] == 'x' or ref[1] == 'X') std.fmt.parseInt(u21, ref[2..], 16) catch null else std.fmt.parseInt(u21, ref[1..], 10) catch null;
                if (cp) |code| {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(code, &buf) catch 0;
                    try out.appendSlice(arena, buf[0..n]);
                    i = semi + 1;
                    continue :outer;
                }
            }
            for (names) |e| if (std.mem.eql(u8, ref, e[0])) {
                try out.appendSlice(arena, e[1]);
                i = semi + 1;
                continue :outer;
            };
        };
        try out.append(arena, s[i]);
        i += 1;
    }
}

const test_pal: md.Palette = .{ .code = .hex(0xff0000), .code_bg = .hex(0x111111), .link = .hex(0x0000ff), .muted = .hex(0x777777) };

test "a README's HTML: centered pictures, headings, links, small print" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\<p align="center">
        \\  <img src="docs/nano.png" alt="Nano, a mouse" width="280">
        \\</p>
        \\
        \\<h1 align="center">nanoui</h1>
        \\
        \\<p align="center"><sub>Meet Nano. <a href="x.png">Transparent PNG</a> &middot; done</sub></p>
        \\
        \\<!-- a comment
        \\that spans lines -->
        \\
        \\Plain **markdown** with a<br>break and <kbd>⌘</kbd> key.
        \\
        \\<details><summary>What's in it</summary>
        \\
        \\- an item
        \\
        \\</details>
    ;
    const blocks = md.parse(arena.allocator(), src, test_pal);
    try std.testing.expectEqual(@as(usize, 6), blocks.len);
    const pic = blocks[0].paragraph;
    try std.testing.expect(pic.center);
    try std.testing.expectEqualStrings("docs/nano.png", pic.images[0].src);
    try std.testing.expectEqual(@as(?f32, 280), pic.images[0].width);
    try std.testing.expectEqualStrings("Nano, a mouse", pic.text[pic.images[0].start..pic.images[0].end]);
    try std.testing.expectEqual(@as(u8, 1), blocks[1].heading.level);
    try std.testing.expect(blocks[1].heading.text.center);
    try std.testing.expectEqualStrings("nanoui", blocks[1].heading.text.text);
    const sub = blocks[2].paragraph;
    try std.testing.expectEqualStrings("Meet Nano. Transparent PNG · done", sub.text);
    try std.testing.expect(sub.spans[0].color != null);
    try std.testing.expectEqualStrings("Plain markdown with a\nbreak and ⌘ key.", blocks[3].paragraph.text);
    try std.testing.expectEqualStrings("What's in it", blocks[4].paragraph.text);
    try std.testing.expectEqualStrings("an item", blocks[5].item.text.text);
    try std.testing.expectEqualStrings("center", attr("align=\"center\" width=280", "align").?);
    try std.testing.expectEqualStrings("280", attr("align=\"center\" width=280", "width").?);
}
