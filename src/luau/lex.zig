//! Luau's tokens: names and keywords, numbers (hex, binary, `1_000`),
//! strings (quoted with escapes, long brackets, backticks), comments, and
//! the operators, including Luau's compound assignments.
const std = @import("std");

pub const Tag = enum {
    eof,
    name,
    number,
    string,
    /// A backtick string, raw: the parser splits out its `{…}`.
    interp,
    // Keywords.
    @"and",
    @"break",
    do,
    @"else",
    elseif,
    end,
    false,
    @"for",
    function,
    @"if",
    in,
    local,
    nil,
    not,
    @"or",
    repeat,
    @"return",
    then,
    true,
    until,
    @"while",
    // Symbols.
    plus,
    minus,
    star,
    slash,
    slash2,
    percent,
    caret,
    hash,
    eq2,
    ne,
    le,
    ge,
    lt,
    gt,
    eq,
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    semi,
    colon,
    colon2,
    comma,
    dot,
    dot2,
    dot3,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    slash2_eq,
    percent_eq,
    caret_eq,
    dot2_eq,
    arrow,
    question,
    pipe,
    amp,
};

pub const Token = struct {
    tag: Tag,
    /// The source text; for strings, the decoded value.
    text: []const u8,
    number: f64 = 0,
    line: u32,
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    /// Decoded strings live here.
    arena: std.mem.Allocator,
    err: []const u8 = "",

    pub fn next(l: *Lexer) error{Syntax}!Token {
        try l.skipSpace();
        const start = l.pos;
        if (l.pos >= l.src.len) return l.tok(.eof, start);
        const ch = l.src[l.pos];
        if (std.ascii.isAlphabetic(ch) or ch == '_') {
            while (l.pos < l.src.len and (std.ascii.isAlphanumeric(l.src[l.pos]) or l.src[l.pos] == '_')) l.pos += 1;
            const word = l.src[start..l.pos];
            const kw = std.meta.stringToEnum(Tag, word);
            if (kw) |k| if (@intFromEnum(k) >= @intFromEnum(Tag.@"and") and @intFromEnum(k) <= @intFromEnum(Tag.@"while")) return l.tok(k, start);
            return l.tok(.name, start);
        }
        if (std.ascii.isDigit(ch) or (ch == '.' and l.pos + 1 < l.src.len and std.ascii.isDigit(l.src[l.pos + 1]))) return l.number();
        if (ch == '"' or ch == '\'') return l.quoted(ch);
        if (ch == '`') return l.backtick();
        if (ch == '[') {
            if (l.longOpen()) |level| return l.long(level, start);
        }
        const three = [_]struct { []const u8, Tag }{
            .{ "...", .dot3 }, .{ "..=", .dot2_eq }, .{ "//=", .slash2_eq },
        };
        const two = [_]struct { []const u8, Tag }{
            .{ "==", .eq2 },      .{ "~=", .ne },        .{ "<=", .le },       .{ ">=", .ge },
            .{ "//", .slash2 },   .{ "::", .colon2 },    .{ "..", .dot2 },     .{ "+=", .plus_eq },
            .{ "-=", .minus_eq }, .{ "*=", .star_eq },   .{ "/=", .slash_eq }, .{ "%=", .percent_eq },
            .{ "^=", .caret_eq }, .{ "->", .arrow },
        };
        const rest = l.src[l.pos..];
        inline for (three) |t| if (std.mem.startsWith(u8, rest, t[0])) {
            l.pos += 3;
            return l.tok(t[1], start);
        };
        inline for (two) |t| if (std.mem.startsWith(u8, rest, t[0])) {
            l.pos += 2;
            return l.tok(t[1], start);
        };
        const one: Tag = switch (ch) {
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '^' => .caret,
            '#' => .hash,
            '<' => .lt,
            '>' => .gt,
            '=' => .eq,
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            ';' => .semi,
            ':' => .colon,
            ',' => .comma,
            '.' => .dot,
            '?' => .question,
            '|' => .pipe,
            '&' => .amp,
            else => return l.fail("unexpected character"),
        };
        l.pos += 1;
        return l.tok(one, start);
    }

    fn tok(l: *Lexer, tag: Tag, start: usize) Token {
        return .{ .tag = tag, .text = l.src[start..l.pos], .line = l.line };
    }

    fn fail(l: *Lexer, msg: []const u8) error{Syntax} {
        l.err = msg;
        return error.Syntax;
    }

    fn skipSpace(l: *Lexer) error{Syntax}!void {
        while (l.pos < l.src.len) {
            const ch = l.src[l.pos];
            if (ch == '\n') {
                l.line += 1;
                l.pos += 1;
            } else if (ch == ' ' or ch == '\t' or ch == '\r') {
                l.pos += 1;
            } else if (std.mem.startsWith(u8, l.src[l.pos..], "--")) {
                l.pos += 2;
                if (l.pos < l.src.len and l.src[l.pos] == '[') if (l.longOpen()) |level| {
                    _ = try l.long(level, l.pos);
                    continue;
                };
                while (l.pos < l.src.len and l.src[l.pos] != '\n') l.pos += 1;
            } else break;
        }
    }

    fn number(l: *Lexer) error{Syntax}!Token {
        const start = l.pos;
        var buf: std.ArrayList(u8) = .empty;
        const s = l.src;
        var base: u8 = 10;
        if (s[l.pos] == '0' and l.pos + 1 < s.len and (s[l.pos + 1] == 'x' or s[l.pos + 1] == 'X')) {
            base = 16;
            l.pos += 2;
        } else if (s[l.pos] == '0' and l.pos + 1 < s.len and (s[l.pos + 1] == 'b' or s[l.pos + 1] == 'B')) {
            base = 2;
            l.pos += 2;
        }
        while (l.pos < s.len) : (l.pos += 1) {
            const ch = s[l.pos];
            if (ch == '_') continue;
            const ok = switch (base) {
                16 => std.ascii.isHex(ch),
                2 => ch == '0' or ch == '1',
                else => std.ascii.isDigit(ch) or ch == '.' or ch == 'e' or ch == 'E' or
                    ((ch == '+' or ch == '-') and (s[l.pos - 1] == 'e' or s[l.pos - 1] == 'E')),
            };
            if (!ok) break;
            buf.append(l.arena, ch) catch return l.fail("out of memory");
        }
        var t = l.tok(.number, start);
        if (base == 10) {
            t.number = std.fmt.parseFloat(f64, buf.items) catch return l.fail("malformed number");
        } else {
            const n = std.fmt.parseInt(u64, buf.items, base) catch return l.fail("malformed number");
            t.number = @floatFromInt(n);
        }
        if (l.pos < s.len and (std.ascii.isAlphabetic(s[l.pos]) or s[l.pos] == '_')) return l.fail("malformed number");
        return t;
    }

    fn quoted(l: *Lexer, q: u8) error{Syntax}!Token {
        const start = l.pos;
        l.pos += 1;
        var buf: std.ArrayList(u8) = .empty;
        while (true) {
            if (l.pos >= l.src.len or l.src[l.pos] == '\n') return l.fail("unfinished string");
            const ch = l.src[l.pos];
            if (ch == q) break;
            if (ch == '\\') {
                try l.escape(&buf);
                continue;
            }
            buf.append(l.arena, ch) catch return l.fail("out of memory");
            l.pos += 1;
        }
        l.pos += 1;
        var t = l.tok(.string, start);
        t.text = buf.items;
        return t;
    }

    /// The escape at `pos` (a backslash), decoded onto `buf`.
    fn escape(l: *Lexer, buf: *std.ArrayList(u8)) error{Syntax}!void {
        l.pos += 1;
        if (l.pos >= l.src.len) return l.fail("unfinished string");
        const e = l.src[l.pos];
        l.pos += 1;
        const a = l.arena;
        const simple: ?u8 = switch (e) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'a' => 7,
            'b' => 8,
            'f' => 12,
            'v' => 11,
            '\\' => '\\',
            '"' => '"',
            '\'' => '\'',
            '`' => '`',
            '{' => '{',
            '\n' => blk: {
                l.line += 1;
                break :blk '\n';
            },
            else => null,
        };
        if (simple) |c| return buf.append(a, c) catch l.fail("out of memory");
        if (e == 'x') {
            if (l.pos + 2 > l.src.len) return l.fail("malformed escape");
            const n = std.fmt.parseInt(u8, l.src[l.pos .. l.pos + 2], 16) catch return l.fail("malformed escape");
            l.pos += 2;
            return buf.append(a, n) catch l.fail("out of memory");
        }
        if (e == 'z') {
            while (l.pos < l.src.len and std.ascii.isWhitespace(l.src[l.pos])) : (l.pos += 1) {
                if (l.src[l.pos] == '\n') l.line += 1;
            }
            return;
        }
        if (e == 'u') {
            if (l.pos >= l.src.len or l.src[l.pos] != '{') return l.fail("malformed escape");
            const close = std.mem.indexOfScalarPos(u8, l.src, l.pos, '}') orelse return l.fail("malformed escape");
            const cp = std.fmt.parseInt(u21, l.src[l.pos + 1 .. close], 16) catch return l.fail("malformed escape");
            l.pos = close + 1;
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &tmp) catch return l.fail("malformed escape");
            return buf.appendSlice(a, tmp[0..n]) catch l.fail("out of memory");
        }
        if (std.ascii.isDigit(e)) {
            var n: u32 = e - '0';
            var k: usize = 0;
            while (k < 2 and l.pos < l.src.len and std.ascii.isDigit(l.src[l.pos])) : (k += 1) {
                n = n * 10 + (l.src[l.pos] - '0');
                l.pos += 1;
            }
            if (n > 255) return l.fail("malformed escape");
            return buf.append(a, @intCast(n)) catch l.fail("out of memory");
        }
        return l.fail("malformed escape");
    }

    fn backtick(l: *Lexer) error{Syntax}!Token {
        const start = l.pos;
        l.pos += 1;
        var depth: usize = 0;
        while (true) {
            if (l.pos >= l.src.len) return l.fail("unfinished string");
            const ch = l.src[l.pos];
            if (ch == '\\') {
                l.pos += 2;
                continue;
            }
            if (ch == '\n') l.line += 1;
            if (ch == '{') depth += 1;
            if (ch == '}' and depth > 0) depth -= 1;
            if (ch == '`' and depth == 0) break;
            l.pos += 1;
        }
        l.pos += 1;
        var t = l.tok(.interp, start);
        t.text = l.src[start + 1 .. l.pos - 1];
        return t;
    }

    /// At `[`: the level of a long bracket (`[[`, `[=[`…), or null.
    fn longOpen(l: *Lexer) ?usize {
        var i = l.pos + 1;
        while (i < l.src.len and l.src[i] == '=') i += 1;
        if (i < l.src.len and l.src[i] == '[') return i - l.pos - 1;
        return null;
    }

    fn long(l: *Lexer, level: usize, start: usize) error{Syntax}!Token {
        l.pos += level + 2;
        if (l.pos < l.src.len and l.src[l.pos] == '\r') l.pos += 1;
        if (l.pos < l.src.len and l.src[l.pos] == '\n') {
            l.line += 1;
            l.pos += 1;
        }
        const body = l.pos;
        while (l.pos < l.src.len) : (l.pos += 1) {
            if (l.src[l.pos] == '\n') l.line += 1;
            if (l.src[l.pos] != ']') continue;
            var i = l.pos + 1;
            while (i < l.src.len and l.src[i] == '=') i += 1;
            if (i - l.pos - 1 == level and i < l.src.len and l.src[i] == ']') {
                const text = l.src[body..l.pos];
                l.pos = i + 1;
                var t = l.tok(.string, start);
                t.text = text;
                return t;
            }
        }
        return l.fail("unfinished long string");
    }
};

/// Decodes the escapes of a piece of a backtick string.
pub fn unescape(arena: std.mem.Allocator, raw: []const u8) error{Syntax}![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var l: Lexer = .{ .src = raw, .arena = arena };
    var buf: std.ArrayList(u8) = .empty;
    while (l.pos < raw.len) {
        if (raw[l.pos] == '\\') {
            try l.escape(&buf);
        } else {
            buf.append(arena, raw[l.pos]) catch return error.Syntax;
            l.pos += 1;
        }
    }
    return buf.items;
}
