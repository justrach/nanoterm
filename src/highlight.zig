//! Syntax colors for code blocks, the way editors' simplest modes do it:
//! comments, strings, numbers, keywords, types and calls, by language
//! family. Enough to read code an agent writes; not a parser.
const std = @import("std");
const nanoui = @import("nanoui");
const Span = nanoui.ui.Span;
const Color = nanoui.ui.Color;

pub const Palette = struct {
    keyword: Color,
    string: Color,
    number: Color,
    comment: Color,
    type: Color,
    call: Color,
};

const Lang = struct {
    line_comment: []const u8 = "//",
    block_comments: bool = true,
    keywords: []const []const u8,
};

const c_like = [_][]const u8{ "if", "else", "for", "while", "return", "break", "continue", "switch", "case", "default", "const", "var", "let", "fn", "func", "function", "struct", "enum", "union", "type", "interface", "class", "impl", "trait", "pub", "public", "private", "static", "import", "export", "from", "package", "use", "mod", "match", "try", "catch", "defer", "errdefer", "async", "await", "new", "delete", "true", "false", "null", "nil", "undefined", "self", "this", "and", "or", "orelse", "comptime", "inline", "extern", "mut", "where", "in", "of", "as", "do", "go", "chan", "map", "void", "int", "bool", "throw", "throws", "extends", "implements", "yield", "unreachable", "usize", "u8", "i32", "u32", "i64", "u64", "f32", "f64", "string", "number", "any" };
const python = [_][]const u8{ "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as", "with", "try", "except", "finally", "raise", "pass", "break", "continue", "lambda", "yield", "None", "True", "False", "and", "or", "not", "in", "is", "async", "await", "global", "nonlocal", "self" };
const shell = [_][]const u8{ "if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "case", "esac", "function", "return", "export", "local", "echo", "cd", "sudo", "set", "unset", "source" };

fn langOf(name: []const u8) ?Lang {
    const sh = [_][]const u8{ "sh", "bash", "zsh", "shell", "console", "fish" };
    for (sh) |n| if (std.ascii.eqlIgnoreCase(name, n)) return .{ .line_comment = "#", .block_comments = false, .keywords = &shell };
    const py = [_][]const u8{ "py", "python", "rb", "ruby", "toml", "yaml", "yml" };
    for (py) |n| if (std.ascii.eqlIgnoreCase(name, n)) return .{ .line_comment = "#", .block_comments = false, .keywords = &python };
    const plain = [_][]const u8{ "text", "txt", "plain", "diff", "output", "log", "md", "markdown" };
    for (plain) |n| if (std.ascii.eqlIgnoreCase(name, n)) return null;
    return .{ .keywords = &c_like };
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '@' or ch == '$';
}

/// Spans coloring one `line` of code in `lang` (into `out`); `in_block`
/// carries a /* comment */ across lines.
pub fn line(arena: std.mem.Allocator, src: []const u8, lang_name: []const u8, pal: Palette, in_block: *bool) []const Span {
    var out: std.ArrayList(Span) = .empty;
    const lang = langOf(lang_name) orelse return diffLine(arena, src, lang_name, pal);
    var i: usize = 0;
    const add = struct {
        fn f(o: *std.ArrayList(Span), a: std.mem.Allocator, start: usize, end: usize, color: Color) void {
            if (end > start) o.append(a, .{ .start = @intCast(start), .end = @intCast(end), .color = color }) catch {};
        }
    }.f;
    if (in_block.*) {
        const close = std.mem.indexOf(u8, src, "*/");
        const end = if (close) |c| c + 2 else src.len;
        add(&out, arena, 0, end, pal.comment);
        if (close == null) return out.items;
        in_block.* = false;
        i = end;
    }
    while (i < src.len) {
        const rest = src[i..];
        if (std.mem.startsWith(u8, rest, lang.line_comment)) {
            add(&out, arena, i, src.len, pal.comment);
            break;
        }
        if (lang.block_comments and std.mem.startsWith(u8, rest, "/*")) {
            const close = std.mem.indexOfPos(u8, src, i + 2, "*/");
            const end = if (close) |c| c + 2 else src.len;
            add(&out, arena, i, end, pal.comment);
            if (close == null) in_block.* = true;
            i = end;
            continue;
        }
        const ch = src[i];
        if (ch == '"' or ch == '\'' or ch == '`') {
            var j = i + 1;
            while (j < src.len and src[j] != ch) : (j += 1) {
                if (src[j] == '\\') j += 1;
            }
            const end = @min(src.len, j + 1);
            add(&out, arena, i, end, pal.string);
            i = end;
            continue;
        }
        if (std.ascii.isDigit(ch) and (i == 0 or !isIdent(src[i - 1]))) {
            var j = i;
            while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '.' or src[j] == '_')) j += 1;
            add(&out, arena, i, j, pal.number);
            i = j;
            continue;
        }
        if (isIdent(ch)) {
            var j = i;
            while (j < src.len and isIdent(src[j])) j += 1;
            const word = src[i..j];
            var color: ?Color = null;
            for (lang.keywords) |k| if (std.mem.eql(u8, k, word)) {
                color = pal.keyword;
                break;
            };
            if (color == null and j < src.len and src[j] == '(') color = pal.call;
            if (color == null and std.ascii.isUpper(word[0]) and word.len > 1) color = pal.type;
            if (color) |c| add(&out, arena, i, j, c);
            i = j;
            continue;
        }
        i += 1;
    }
    return out.items;
}

/// Diffs: added lines green, removed red, hunks in the keyword color.
fn diffLine(arena: std.mem.Allocator, src: []const u8, lang: []const u8, pal: Palette) []const Span {
    if (!std.ascii.eqlIgnoreCase(lang, "diff") or src.len == 0) return &.{};
    const color: ?Color = switch (src[0]) {
        '+' => pal.string,
        '-' => pal.number,
        '@' => pal.keyword,
        else => null,
    };
    const c = color orelse return &.{};
    const out = arena.alloc(Span, 1) catch return &.{};
    out[0] = .{ .start = 0, .end = @intCast(src.len), .color = c };
    return out;
}

test "highlighting" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const pal: Palette = .{ .keyword = .hex(1), .string = .hex(2), .number = .hex(3), .comment = .hex(4), .type = .hex(5), .call = .hex(6) };
    var block = false;
    const spans = line(arena.allocator(), "const x = foo(\"hi\", 42); // done", "zig", pal, &block);
    try std.testing.expectEqual(@as(usize, 5), spans.len);
    try std.testing.expectEqual(pal.keyword, spans[0].color.?);
    try std.testing.expectEqual(pal.call, spans[1].color.?);
    try std.testing.expectEqual(pal.string, spans[2].color.?);
    try std.testing.expectEqual(pal.number, spans[3].color.?);
    try std.testing.expectEqual(pal.comment, spans[4].color.?);
    _ = line(arena.allocator(), "a /* open", "c", pal, &block);
    try std.testing.expect(block);
    const closing = line(arena.allocator(), "still */ b", "c", pal, &block);
    try std.testing.expect(!block);
    try std.testing.expectEqual(@as(u32, 8), closing[0].end);
    const shell_spans = line(arena.allocator(), "echo $HOME # note", "sh", pal, &block);
    try std.testing.expectEqual(pal.comment, shell_spans[shell_spans.len - 1].color.?);
}
