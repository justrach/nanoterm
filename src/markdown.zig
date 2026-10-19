//! Markdown, as agents write it: headings, paragraphs, bullet, numbered
//! and task lists, quotes, rules, fenced code, tables; and inline
//! **bold**, *italics*, `code`, ~~struck~~ text and [links](…); and the
//! HTML READMEs mix in (`markdown_html.zig`). Parsed into blocks whose
//! text carries nanoui spans, in the frame's memory.
const std = @import("std");
const nanoui = @import("nanoui");
const html = @import("markdown_html.zig");
const Span = nanoui.ui.Span;
const Color = nanoui.ui.Color;

/// The colors inline marks take.
pub const Palette = struct {
    code: Color,
    code_bg: Color,
    link: Color,
    /// HTML's small print (`<sub>`, `<small>`).
    muted: ?Color = null,
};

/// Text with its spans: sorted, never overlapping.
pub const Inline = struct {
    text: []const u8,
    spans: []const Span,
    /// Pictures (`![alt](src)`): their source, and where their alt text is
    /// in `text` (drawn as a link where the picture can't be shown).
    images: []const Image = &.{},
    /// Centered, as HTML's `align="center"` asks.
    center: bool = false,
};

/// A picture: its source, where its alt text is in the text, and the
/// width HTML gave it.
pub const Image = struct { src: []const u8, start: u32, end: u32, width: ?f32 = null };

pub const Block = union(enum) {
    paragraph: Inline,
    heading: struct { level: u8, text: Inline },
    code: struct { lang: []const u8, text: []const u8 },
    item: struct { depth: u8, marker: []const u8, task: ?bool = null, text: Inline },
    quote: Inline,
    rule,
    table: struct { header: []const Inline, rows: []const []const Inline },
};

pub fn parse(arena: std.mem.Allocator, src: []const u8, pal: Palette) []const Block {
    var p: Parser = .{ .arena = arena, .pal = pal };
    p.run(src) catch {};
    return p.blocks.items;
}

pub const Parser = struct {
    arena: std.mem.Allocator,
    pal: Palette,
    blocks: std.ArrayList(Block) = .empty,
    /// Lines of the paragraph (or list item, quote) being gathered.
    para: std.ArrayList(u8) = .empty,
    para_kind: enum { none, paragraph, item, quote } = .none,
    item_depth: u8 = 0,
    item_marker: []const u8 = "",
    item_task: ?bool = null,

    fn flush(p: *Parser) !void {
        if (p.para_kind == .none) return;
        const text = try p.inlines(std.mem.trim(u8, p.para.items, " \n"));
        switch (p.para_kind) {
            .paragraph => try p.blocks.append(p.arena, .{ .paragraph = text }),
            .item => try p.blocks.append(p.arena, .{ .item = .{ .depth = p.item_depth, .marker = p.item_marker, .task = p.item_task, .text = text } }),
            .quote => try p.blocks.append(p.arena, .{ .quote = text }),
            .none => {},
        }
        p.para = .empty;
        p.para_kind = .none;
    }

    fn gather(p: *Parser, line: []const u8) !void {
        if (p.para.items.len > 0) {
            // Two trailing spaces break the line; otherwise lines join.
            const hard = std.mem.endsWith(u8, p.para.items, "  ");
            try p.para.append(p.arena, if (hard) '\n' else ' ');
        }
        try p.para.appendSlice(p.arena, std.mem.trim(u8, line, " \t"));
    }

    fn run(p: *Parser, src: []const u8) !void {
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, src, '\n');
        while (it.next()) |l| try lines.append(p.arena, std.mem.trimEnd(u8, l, "\r"));
        var i: usize = 0;
        while (i < lines.items.len) : (i += 1) {
            const line = lines.items[i];
            const t = std.mem.trim(u8, line, " \t");
            const indent = line.len - std.mem.trimStart(u8, line, " \t").len;
            if (t.len == 0) {
                try p.flush();
                continue;
            }
            // A fence: everything to the closing fence (or the end, while it streams).
            if (std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~")) {
                try p.flush();
                const fence = t[0..3];
                const lang = std.mem.trim(u8, t[3..], " `~");
                var body: std.ArrayList(u8) = .empty;
                i += 1;
                while (i < lines.items.len) : (i += 1) {
                    const l = lines.items[i];
                    if (std.mem.startsWith(u8, std.mem.trimStart(u8, l, " \t"), fence)) break;
                    if (body.items.len > 0) try body.append(p.arena, '\n');
                    try body.appendSlice(p.arena, if (l.len >= indent and indent > 0) l[indent..] else l);
                }
                // A fence still streaming ends at its last full line.
                try p.blocks.append(p.arena, .{ .code = .{ .lang = lang, .text = std.mem.trimEnd(u8, body.items, "\n ") } });
                continue;
            }
            // HTML, to the blank line that ends it (a comment to its end).
            if (html.starts(t)) {
                try p.flush();
                const comment = std.mem.startsWith(u8, t, "<!--");
                var body: std.ArrayList(u8) = .empty;
                while (i < lines.items.len) : (i += 1) {
                    const l = lines.items[i];
                    if (!comment and std.mem.trim(u8, l, " \t").len == 0) break;
                    try body.appendSlice(p.arena, l);
                    try body.append(p.arena, '\n');
                    if (comment and std.mem.indexOf(u8, l, "-->") != null) break;
                }
                try html.convert(p.arena, p.pal, body.items, &p.blocks);
                continue;
            }
            if (heading(t)) |level| {
                try p.flush();
                try p.blocks.append(p.arena, .{ .heading = .{ .level = level, .text = try p.inlines(std.mem.trim(u8, t[level..], " #")) } });
                continue;
            }
            if (isRule(t)) {
                try p.flush();
                try p.blocks.append(p.arena, .rule);
                continue;
            }
            if (t[0] == '|' and i + 1 < lines.items.len and isTableRule(lines.items[i + 1])) {
                try p.flush();
                const header = try p.cells(t);
                var rows: std.ArrayList([]const Inline) = .empty;
                i += 2;
                while (i < lines.items.len) : (i += 1) {
                    const r = std.mem.trim(u8, lines.items[i], " \t");
                    if (r.len == 0 or r[0] != '|') break;
                    try rows.append(p.arena, try p.cells(r));
                }
                if (i < lines.items.len) i -= 1;
                try p.blocks.append(p.arena, .{ .table = .{ .header = header, .rows = rows.items } });
                continue;
            }
            if (t[0] == '>') {
                if (p.para_kind != .quote) try p.flush();
                p.para_kind = .quote;
                try p.gather(std.mem.trimStart(u8, t[1..], " "));
                continue;
            }
            if (listItem(t)) |li| {
                try p.flush();
                p.para_kind = .item;
                p.item_depth = @intCast(@min(indent / 2, 6));
                p.item_marker = li.marker;
                p.item_task = li.task;
                try p.gather(li.rest);
                continue;
            }
            // A continuation of the open item or quote, or a paragraph's line.
            if (p.para_kind == .none) p.para_kind = .paragraph;
            try p.gather(t);
        }
        try p.flush();
    }

    fn cells(p: *Parser, row: []const u8) ![]const Inline {
        var out: std.ArrayList(Inline) = .empty;
        const inner = std.mem.trim(u8, row, " \t|");
        var it = std.mem.splitScalar(u8, inner, '|');
        while (it.next()) |cell| try out.append(p.arena, try p.inlines(std.mem.trim(u8, cell, " ")));
        return out.items;
    }

    // Inline marks.

    pub const Flags = struct { bold: bool = false, italic: bool = false, code: bool = false, strike: bool = false, link: bool = false, muted: bool = false };

    fn inlines(p: *Parser, src: []const u8) !Inline {
        var b: Builder = .{ .arena = p.arena, .pal = p.pal };
        try b.parse(src, .{});
        return .{ .text = b.text.items, .spans = b.spans.items, .images = b.images.items };
    }

    pub const Builder = struct {
        arena: std.mem.Allocator,
        pal: Palette,
        text: std.ArrayList(u8) = .empty,
        spans: std.ArrayList(Span) = .empty,
        images: std.ArrayList(Image) = .empty,

        pub fn emit(b: *Builder, s: []const u8, f: Flags) !void {
            if (s.len == 0) return;
            const start: u32 = @intCast(b.text.items.len);
            try b.text.appendSlice(b.arena, s);
            const end: u32 = @intCast(b.text.items.len);
            if (!f.bold and !f.italic and !f.code and !f.strike and !f.link and !f.muted) return;
            const span: Span = .{
                .start = start,
                .end = end,
                .weight = if (f.bold) .semibold else null,
                .italic = f.italic,
                .mono = f.code,
                .color = if (f.code) b.pal.code else if (f.link) b.pal.link else if (f.muted) b.pal.muted else null,
                .background = if (f.code) b.pal.code_bg else null,
                .underline = f.link,
                .strike = f.strike,
            };
            if (b.spans.items.len > 0) {
                const last = &b.spans.items[b.spans.items.len - 1];
                var same = last.*;
                same.start = span.start;
                same.end = span.end;
                if (last.end == start and std.meta.eql(same, span)) {
                    last.end = end;
                    return;
                }
            }
            try b.spans.append(b.arena, span);
        }

        fn parse(b: *Builder, src: []const u8, f: Flags) anyerror!void {
            var i: usize = 0;
            var plain: usize = 0;
            while (i < src.len) {
                const ch = src[i];
                const rest = src[i..];
                if (ch == '\\' and i + 1 < src.len and std.mem.indexOfScalar(u8, "\\`*_{}[]()#+-.!~|<>", src[i + 1]) != null) {
                    try b.emit(src[plain..i], f);
                    plain = i + 1;
                    i += 2;
                    continue;
                }
                if (ch == '`') {
                    var n: usize = 0;
                    while (i + n < src.len and src[i + n] == '`') n += 1;
                    if (std.mem.indexOf(u8, src[i + n ..], src[i .. i + n])) |close| {
                        try b.emit(src[plain..i], f);
                        var cf = f;
                        cf.code = true;
                        try b.emit(std.mem.trim(u8, src[i + n .. i + n + close], " "), cf);
                        i += n + close + n;
                        plain = i;
                        continue;
                    }
                }
                if (ch == '*' or ch == '_' or ch == '~') {
                    const double = rest.len > 1 and rest[1] == ch;
                    const mark = if (double) rest[0..2] else rest[0..1];
                    // `_` inside a word (snake_case) is not a mark; `~` needs two.
                    const in_word = ch == '_' and i > 0 and std.ascii.isAlphanumeric(src[i - 1]);
                    const opens = rest.len > mark.len and rest[mark.len] != ' ';
                    if (!in_word and opens and (ch != '~' or double)) {
                        if (closing(src, i + mark.len, mark)) |close| {
                            try b.emit(src[plain..i], f);
                            var nf = f;
                            if (ch == '~') nf.strike = true else if (double) nf.bold = true else nf.italic = true;
                            try b.parse(src[i + mark.len .. close], nf);
                            i = close + mark.len;
                            plain = i;
                            continue;
                        }
                    }
                }
                if (ch == '[' or (ch == '!' and rest.len > 1 and rest[1] == '[')) {
                    const open = if (ch == '!') i + 1 else i;
                    if (std.mem.indexOfScalarPos(u8, src, open, ']')) |close| {
                        if (close + 1 < src.len and src[close + 1] == '(') {
                            if (std.mem.indexOfScalarPos(u8, src, close + 2, ')')) |end| {
                                try b.emit(src[plain..i], f);
                                var lf = f;
                                lf.link = true;
                                const at: u32 = @intCast(b.text.items.len);
                                try b.parse(src[open + 1 .. close], lf);
                                if (ch == '!') try b.images.append(b.arena, .{ .src = std.mem.trim(u8, src[close + 2 .. end], " <>"), .start = at, .end = @intCast(b.text.items.len) });
                                i = end + 1;
                                plain = i;
                                continue;
                            }
                        }
                    }
                }
                // An inline HTML tag: a line break, or a mark left out.
                if (ch == '<') if (html.inlineTag(rest)) |tag| {
                    try b.emit(src[plain..i], f);
                    if (tag.br) try b.emit("\n", f);
                    i += tag.len;
                    plain = i;
                    continue;
                };
                if (std.mem.startsWith(u8, rest, "https://") or std.mem.startsWith(u8, rest, "http://")) {
                    var end = i;
                    while (end < src.len and src[end] != ' ' and src[end] != ')' and src[end] != '>') end += 1;
                    while (end > i and std.mem.indexOfScalar(u8, ".,;:!?", src[end - 1]) != null) end -= 1;
                    try b.emit(src[plain..i], f);
                    var lf = f;
                    lf.link = true;
                    try b.emit(src[i..end], lf);
                    i = end;
                    plain = i;
                    continue;
                }
                i += 1;
            }
            try b.emit(src[plain..], f);
        }
    };
};

/// Where `mark` closes, after `from`: not after a space, not escaped.
fn closing(src: []const u8, from: usize, mark: []const u8) ?usize {
    var i = from;
    while (std.mem.indexOfPos(u8, src, i, mark)) |at| {
        const before_ok = at > from and src[at - 1] != ' ' and src[at - 1] != '\\';
        // `**a**b`: a single mark must not be half of a double one.
        const doubled = mark.len == 1 and at + 1 < src.len and src[at + 1] == mark[0];
        if (before_ok and !doubled) return at;
        i = at + if (doubled) @as(usize, 2) else 1;
    }
    return null;
}

fn heading(t: []const u8) ?u8 {
    var n: u8 = 0;
    while (n < t.len and n < 6 and t[n] == '#') n += 1;
    if (n == 0 or n >= t.len or t[n] != ' ') return null;
    return n;
}

fn isRule(t: []const u8) bool {
    if (t.len < 3) return false;
    const ch = t[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (t) |x| if (x != ch and x != ' ') return false;
    return true;
}

fn isTableRule(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < 3 or std.mem.indexOfScalar(u8, t, '-') == null) return false;
    for (t) |x| if (std.mem.indexOfScalar(u8, "|-: ", x) == null) return false;
    return true;
}

const ListItem = struct { marker: []const u8, rest: []const u8, task: ?bool };

fn listItem(t: []const u8) ?ListItem {
    var marker: []const u8 = "";
    var rest: []const u8 = "";
    if (t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and t[1] == ' ') {
        marker = "•";
        rest = t[2..];
    } else {
        var n: usize = 0;
        while (n < t.len and n < 4 and std.ascii.isDigit(t[n])) n += 1;
        if (n == 0 or n + 1 >= t.len or (t[n] != '.' and t[n] != ')') or t[n + 1] != ' ') return null;
        marker = t[0 .. n + 1];
        rest = t[n + 2 ..];
    }
    rest = std.mem.trimStart(u8, rest, " ");
    if (std.mem.startsWith(u8, rest, "[ ] ")) return .{ .marker = marker, .rest = rest[4..], .task = false };
    if (std.mem.startsWith(u8, rest, "[x] ") or std.mem.startsWith(u8, rest, "[X] ")) return .{ .marker = marker, .rest = rest[4..], .task = true };
    return .{ .marker = marker, .rest = rest, .task = null };
}

const test_pal: Palette = .{ .code = .hex(0xff0000), .code_bg = .hex(0x111111), .link = .hex(0x0000ff) };

test "blocks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\# Title
        \\
        \\A paragraph
        \\on two lines.
        \\
        \\- one
        \\  more of one
        \\- [x] done
        \\  1. nested
        \\
        \\> quoted
        \\
        \\```zig
        \\const x = 1;
        \\```
        \\
        \\| a | b |
        \\|---|:-:|
        \\| 1 | 2 |
        \\
        \\---
    ;
    const blocks = parse(arena.allocator(), src, test_pal);
    try std.testing.expectEqual(@as(usize, 9), blocks.len);
    try std.testing.expectEqual(@as(u8, 1), blocks[0].heading.level);
    try std.testing.expectEqualStrings("A paragraph on two lines.", blocks[1].paragraph.text);
    try std.testing.expectEqualStrings("one more of one", blocks[2].item.text.text);
    try std.testing.expectEqual(@as(?bool, true), blocks[3].item.task);
    try std.testing.expectEqualStrings("1.", blocks[4].item.marker);
    try std.testing.expectEqual(@as(u8, 1), blocks[4].item.depth);
    try std.testing.expectEqualStrings("quoted", blocks[5].quote.text);
    try std.testing.expectEqualStrings("zig", blocks[6].code.lang);
    try std.testing.expectEqualStrings("const x = 1;", blocks[6].code.text);
    try std.testing.expectEqual(@as(usize, 2), blocks[7].table.header.len);
    try std.testing.expectEqualStrings("2", blocks[7].table.rows[0][1].text);
    try std.testing.expect(blocks[8] == .rule);
}

test "inline marks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const blocks = parse(arena.allocator(), "Run **`zig build` now**, *see* [the docs](https://x.io) or ~~not~~ snake_case_name and a*b.", test_pal);
    const in = blocks[0].paragraph;
    try std.testing.expectEqualStrings("Run zig build now, see the docs or not snake_case_name and a*b.", in.text);
    // "zig build" is bold code; " now" bold; "see" italic; link; struck.
    try std.testing.expectEqual(@as(usize, 5), in.spans.len);
    try std.testing.expect(in.spans[0].mono and in.spans[0].weight == .semibold);
    try std.testing.expectEqualStrings("zig build", in.text[in.spans[0].start..in.spans[0].end]);
    try std.testing.expectEqualStrings(" now", in.text[in.spans[1].start..in.spans[1].end]);
    try std.testing.expect(in.spans[2].italic);
    try std.testing.expect(in.spans[3].underline);
    try std.testing.expectEqualStrings("the docs", in.text[in.spans[3].start..in.spans[3].end]);
    try std.testing.expect(in.spans[4].strike);
}
