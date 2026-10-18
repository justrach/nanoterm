//! Luau source to a syntax tree: Lua 5.1's grammar with Luau's additions
//! (compound assignment, `continue`, if-expressions, backtick strings,
//! `//`), and its type annotations read and set aside (`local x: number`,
//! `function f(a: T): U`, `e :: T`, `type T = …`).
const std = @import("std");
const ast = @import("ast.zig");
const lex = @import("lex.zig");
const value = @import("value.zig");
const types = @import("parse_types.zig");
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Tag = lex.Tag;

pub const Error = error{Syntax};

/// How deep expressions and blocks may nest.
const max_depth = 160;

pub const Parser = struct {
    lexer: lex.Lexer,
    arena: std.mem.Allocator,
    /// Constant strings are made on the heap once, and fixed.
    heap: *value.Heap,
    tok: lex.Token = undefined,
    ahead: ?lex.Token = null,
    depth: usize = 0,
    err: []const u8 = "",
    err_line: u32 = 0,

    pub fn init(arena: std.mem.Allocator, heap: *value.Heap, src: []const u8) Parser {
        return .{ .lexer = .{ .src = src, .arena = arena }, .arena = arena, .heap = heap };
    }

    /// The whole source, as the body of a function with no parameters.
    pub fn chunk(p: *Parser) Error!*ast.Func {
        try p.advance();
        const body = try p.block();
        if (p.tok.tag != .eof) return p.fail("'<eof>' expected");
        return p.make(ast.Func, .{ .params = &.{}, .body = body, .name = "main chunk", .line = 0 });
    }

    pub fn advance(p: *Parser) Error!void {
        if (p.ahead) |t| {
            p.tok = t;
            p.ahead = null;
            return;
        }
        p.tok = p.lexer.next() catch return p.failLex();
    }

    fn peek(p: *Parser) Error!lex.Token {
        if (p.ahead == null) p.ahead = p.lexer.next() catch return p.failLex();
        return p.ahead.?;
    }

    fn failLex(p: *Parser) Error {
        p.err = p.lexer.err;
        p.err_line = p.lexer.line;
        return error.Syntax;
    }

    pub fn fail(p: *Parser, msg: []const u8) Error {
        p.err = std.fmt.allocPrint(p.arena, "{s} near '{s}'", .{ msg, if (p.tok.tag == .eof) "<eof>" else p.tok.text }) catch msg;
        p.err_line = p.tok.line;
        return error.Syntax;
    }

    fn make(p: *Parser, comptime T: type, v: T) Error!*T {
        const n = p.arena.create(T) catch return p.fail("out of memory");
        n.* = v;
        return n;
    }

    fn expr(p: *Parser, line: u32, kind: @FieldType(Expr, "kind")) Error!*Expr {
        return p.make(Expr, .{ .line = line, .kind = kind });
    }

    fn str(p: *Parser, bytes: []const u8) Error!*value.Str {
        const s = p.heap.str(bytes) catch return p.fail("out of memory");
        s.obj.fixed = true;
        return s;
    }

    fn expect(p: *Parser, tag: Tag, what: []const u8) Error!void {
        if (p.tok.tag != tag) return p.fail(std.fmt.allocPrint(p.arena, "'{s}' expected", .{what}) catch what);
        try p.advance();
    }

    pub fn accept(p: *Parser, tag: Tag) Error!bool {
        if (p.tok.tag != tag) return false;
        try p.advance();
        return true;
    }

    pub fn name(p: *Parser) Error![]const u8 {
        if (p.tok.tag != .name) return p.fail("name expected");
        const n = p.tok.text;
        try p.advance();
        return n;
    }

    pub fn enter(p: *Parser) Error!void {
        p.depth += 1;
        if (p.depth > max_depth) return p.fail("too deeply nested");
    }

    fn blockEnd(tag: Tag) bool {
        return switch (tag) {
            .eof, .end, .@"else", .elseif, .until => true,
            else => false,
        };
    }

    fn block(p: *Parser) Error!*ast.Block {
        try p.enter();
        defer p.depth -= 1;
        var stmts: std.ArrayList(Stmt) = .empty;
        while (!blockEnd(p.tok.tag)) {
            if (try p.accept(.semi)) continue;
            if (p.tok.tag == .@"return") {
                const line = p.tok.line;
                try p.advance();
                var values: []*Expr = &.{};
                if (!blockEnd(p.tok.tag) and p.tok.tag != .semi) values = try p.exprList();
                _ = try p.accept(.semi);
                stmts.append(p.arena, .{ .line = line, .kind = .{ .@"return" = values } }) catch return p.fail("out of memory");
                if (!blockEnd(p.tok.tag)) return p.fail("'end' expected after return");
                break;
            }
            if (try p.statement()) |s| stmts.append(p.arena, s) catch return p.fail("out of memory");
        }
        return p.make(ast.Block, .{ .stmts = stmts.items });
    }

    fn statement(p: *Parser) Error!?Stmt {
        const line = p.tok.line;
        switch (p.tok.tag) {
            .@"if" => return try p.ifStatement(),
            .@"while" => {
                try p.advance();
                const cond = try p.expression();
                try p.expect(.do, "do");
                const body = try p.block();
                try p.expect(.end, "end");
                return .{ .line = line, .kind = .{ .@"while" = .{ .cond = cond, .body = body } } };
            },
            .do => {
                try p.advance();
                const body = try p.block();
                try p.expect(.end, "end");
                return .{ .line = line, .kind = .{ .do = body } };
            },
            .@"for" => return try p.forStatement(),
            .repeat => {
                try p.advance();
                const body = try p.block();
                try p.expect(.until, "until");
                return .{ .line = line, .kind = .{ .repeat = .{ .body = body, .cond = try p.expression() } } };
            },
            .function => {
                try p.advance();
                var target = try p.expr(line, .{ .name = try p.name() });
                var method = false;
                while (p.tok.tag == .dot or p.tok.tag == .colon) {
                    method = p.tok.tag == .colon;
                    try p.advance();
                    const key = try p.expr(p.tok.line, .{ .string = try p.str(try p.name()) });
                    target = try p.expr(line, .{ .index = .{ .obj = target, .key = key } });
                    if (method) break;
                }
                const f = try p.funcBody(method, line, "function");
                const targets = p.arena.alloc(*Expr, 1) catch return p.fail("out of memory");
                targets[0] = target;
                const values = p.arena.alloc(*Expr, 1) catch return p.fail("out of memory");
                values[0] = try p.expr(line, .{ .function = f });
                return .{ .line = line, .kind = .{ .assign = .{ .targets = targets, .values = values } } };
            },
            .local => {
                try p.advance();
                if (try p.accept(.function)) {
                    const n = try p.name();
                    return .{ .line = line, .kind = .{ .local_function = .{ .name = n, .func = try p.funcBody(false, line, n) } } };
                }
                var names: std.ArrayList([]const u8) = .empty;
                while (true) {
                    names.append(p.arena, try p.name()) catch return p.fail("out of memory");
                    if (try p.accept(.colon)) try p.skipType();
                    // Lua 5.4's attributes (<const>, <close>).
                    if (p.tok.tag == .lt) try p.skipBalanced();
                    if (!try p.accept(.comma)) break;
                }
                var values: []*Expr = &.{};
                if (try p.accept(.eq)) values = try p.exprList();
                const slots = p.arena.alloc(u16, names.items.len) catch return p.fail("out of memory");
                return .{ .line = line, .kind = .{ .local = .{ .names = names.items, .slots = slots, .values = values } } };
            },
            .@"break" => {
                try p.advance();
                return .{ .line = line, .kind = .@"break" };
            },
            .name => {
                const next = try p.peek();
                if (std.mem.eql(u8, p.tok.text, "continue") and statementStart(next.tag)) {
                    try p.advance();
                    return .{ .line = line, .kind = .@"continue" };
                }
                // `type T = …` and `export type T = …`: annotations only.
                if ((std.mem.eql(u8, p.tok.text, "type") and next.tag == .name) or
                    (std.mem.eql(u8, p.tok.text, "export") and next.tag == .name and std.mem.eql(u8, next.text, "type")))
                {
                    if (std.mem.eql(u8, p.tok.text, "export")) try p.advance();
                    try p.advance();
                    _ = try p.name();
                    if (p.tok.tag == .lt) try p.skipBalanced();
                    try p.expect(.eq, "=");
                    try p.skipType();
                    return null;
                }
            },
            else => {},
        }
        return try p.exprStatement();
    }

    /// Whether a token can follow `continue` used as the statement.
    fn statementStart(tag: Tag) bool {
        return switch (tag) {
            .eq, .lparen, .dot, .lbracket, .colon, .comma, .string, .lbrace, .interp, .plus_eq, .minus_eq, .star_eq, .slash_eq, .slash2_eq, .percent_eq, .caret_eq, .dot2_eq => false,
            else => true,
        };
    }

    fn exprStatement(p: *Parser) Error!Stmt {
        const line = p.tok.line;
        const first = try p.suffixed();
        if (p.tok.tag == .eq or p.tok.tag == .comma) {
            var targets: std.ArrayList(*Expr) = .empty;
            targets.append(p.arena, first) catch return p.fail("out of memory");
            while (try p.accept(.comma)) targets.append(p.arena, try p.suffixed()) catch return p.fail("out of memory");
            try p.expect(.eq, "=");
            for (targets.items) |t| if (t.kind != .name and t.kind != .index) return p.fail("syntax error");
            return .{ .line = line, .kind = .{ .assign = .{ .targets = targets.items, .values = try p.exprList() } } };
        }
        const op: ?ast.BinOp = switch (p.tok.tag) {
            .plus_eq => .add,
            .minus_eq => .sub,
            .star_eq => .mul,
            .slash_eq => .div,
            .slash2_eq => .idiv,
            .percent_eq => .mod,
            .caret_eq => .pow,
            .dot2_eq => .concat,
            else => null,
        };
        if (op) |o| {
            if (first.kind != .name and first.kind != .index) return p.fail("syntax error");
            try p.advance();
            return .{ .line = line, .kind = .{ .compound = .{ .op = o, .target = first, .value = try p.expression() } } };
        }
        if (first.kind != .call and first.kind != .method) return p.fail("syntax error");
        return .{ .line = line, .kind = .{ .call = first } };
    }

    fn ifStatement(p: *Parser) Error!Stmt {
        const line = p.tok.line;
        var conds: std.ArrayList(*Expr) = .empty;
        var blocks: std.ArrayList(*ast.Block) = .empty;
        var otherwise: ?*ast.Block = null;
        try p.advance();
        while (true) {
            conds.append(p.arena, try p.expression()) catch return p.fail("out of memory");
            try p.expect(.then, "then");
            blocks.append(p.arena, try p.block()) catch return p.fail("out of memory");
            if (try p.accept(.elseif)) continue;
            if (try p.accept(.@"else")) otherwise = try p.block();
            try p.expect(.end, "end");
            break;
        }
        return .{ .line = line, .kind = .{ .@"if" = .{ .conds = conds.items, .blocks = blocks.items, .@"else" = otherwise } } };
    }

    fn forStatement(p: *Parser) Error!Stmt {
        const line = p.tok.line;
        try p.advance();
        const first = try p.name();
        if (try p.accept(.colon)) try p.skipType();
        if (try p.accept(.eq)) {
            const start = try p.expression();
            try p.expect(.comma, ",");
            const limit = try p.expression();
            const step = if (try p.accept(.comma)) try p.expression() else null;
            try p.expect(.do, "do");
            const body = try p.block();
            try p.expect(.end, "end");
            return .{ .line = line, .kind = .{ .numeric_for = .{ .name = first, .start = start, .limit = limit, .step = step, .body = body } } };
        }
        var names: std.ArrayList([]const u8) = .empty;
        names.append(p.arena, first) catch return p.fail("out of memory");
        while (try p.accept(.comma)) {
            names.append(p.arena, try p.name()) catch return p.fail("out of memory");
            if (try p.accept(.colon)) try p.skipType();
        }
        try p.expect(.in, "in");
        const exprs = try p.exprList();
        try p.expect(.do, "do");
        const body = try p.block();
        try p.expect(.end, "end");
        return .{ .line = line, .kind = .{ .generic_for = .{ .names = names.items, .exprs = exprs, .body = body } } };
    }

    /// `(params) body end`, after `function` and its name.
    fn funcBody(p: *Parser, method: bool, line: u32, fname: []const u8) Error!*ast.Func {
        if (p.tok.tag == .lt) try p.skipBalanced(); // generics
        try p.expect(.lparen, "(");
        var params: std.ArrayList([]const u8) = .empty;
        if (method) params.append(p.arena, "self") catch return p.fail("out of memory");
        if (p.tok.tag != .rparen) while (true) {
            if (try p.accept(.dot3)) {
                params.append(p.arena, "...") catch return p.fail("out of memory");
                if (try p.accept(.colon)) try p.skipType();
                break;
            }
            params.append(p.arena, try p.name()) catch return p.fail("out of memory");
            if (try p.accept(.colon)) try p.skipType();
            if (!try p.accept(.comma)) break;
        };
        try p.expect(.rparen, ")");
        if (try p.accept(.colon)) try p.skipType();
        const body = try p.block();
        try p.expect(.end, "end");
        return p.make(ast.Func, .{ .params = params.items, .body = body, .name = fname, .line = line });
    }

    /// One expression, from the first token.
    fn firstExpression(p: *Parser) Error!*Expr {
        try p.advance();
        return p.expression();
    }

    pub fn exprList(p: *Parser) Error![]*Expr {
        var list: std.ArrayList(*Expr) = .empty;
        while (true) {
            list.append(p.arena, try p.expression()) catch return p.fail("out of memory");
            if (!try p.accept(.comma)) break;
        }
        return list.items;
    }

    pub fn expression(p: *Parser) Error!*Expr {
        return p.sub(0);
    }

    const Prec = struct { op: ast.BinOp, left: u8, right: u8 };

    fn binary(tag: Tag) ?Prec {
        return switch (tag) {
            .@"or" => .{ .op = .@"or", .left = 1, .right = 1 },
            .@"and" => .{ .op = .@"and", .left = 2, .right = 2 },
            .lt => .{ .op = .lt, .left = 3, .right = 3 },
            .gt => .{ .op = .gt, .left = 3, .right = 3 },
            .le => .{ .op = .le, .left = 3, .right = 3 },
            .ge => .{ .op = .ge, .left = 3, .right = 3 },
            .ne => .{ .op = .ne, .left = 3, .right = 3 },
            .eq2 => .{ .op = .eq, .left = 3, .right = 3 },
            .dot2 => .{ .op = .concat, .left = 5, .right = 4 },
            .plus => .{ .op = .add, .left = 6, .right = 6 },
            .minus => .{ .op = .sub, .left = 6, .right = 6 },
            .star => .{ .op = .mul, .left = 7, .right = 7 },
            .slash => .{ .op = .div, .left = 7, .right = 7 },
            .slash2 => .{ .op = .idiv, .left = 7, .right = 7 },
            .percent => .{ .op = .mod, .left = 7, .right = 7 },
            .caret => .{ .op = .pow, .left = 10, .right = 9 },
            else => null,
        };
    }

    const unary_priority = 8;

    fn sub(p: *Parser, limit: u8) Error!*Expr {
        try p.enter();
        defer p.depth -= 1;
        const line = p.tok.line;
        var left: *Expr = undefined;
        const un: ?ast.UnOp = switch (p.tok.tag) {
            .not => .not,
            .minus => .neg,
            .hash => .len,
            else => null,
        };
        if (un) |op| {
            try p.advance();
            const e = try p.sub(unary_priority);
            // Fold negative numbers.
            left = if (op == .neg and e.kind == .number) try p.expr(line, .{ .number = -e.kind.number }) else try p.expr(line, .{ .unary = .{ .op = op, .e = e } });
        } else left = try p.simple();
        while (binary(p.tok.tag)) |b| {
            if (b.left <= limit) break;
            const l = p.tok.line;
            try p.advance();
            const right = try p.sub(b.right);
            left = try p.expr(l, .{ .binary = .{ .op = b.op, .l = left, .r = right } });
        }
        return left;
    }

    fn simple(p: *Parser) Error!*Expr {
        const line = p.tok.line;
        const e: *Expr = switch (p.tok.tag) {
            .number => try p.expr(line, .{ .number = p.tok.number }),
            .string => try p.expr(line, .{ .string = try p.str(p.tok.text) }),
            .nil => try p.expr(line, .nil),
            .true => try p.expr(line, .true),
            .false => try p.expr(line, .false),
            .dot3 => try p.expr(line, .{ .vararg = null }),
            .lbrace => return p.casted(try p.table()),
            .function => {
                try p.advance();
                return p.casted(try p.expr(line, .{ .function = try p.funcBody(false, line, "anonymous function") }));
            },
            .@"if" => return p.casted(try p.ifExpression()),
            .interp => try p.interp(),
            else => return p.casted(try p.suffixed()),
        };
        try p.advance();
        return p.casted(e);
    }

    /// `e :: T` is `e`.
    fn casted(p: *Parser, e: *Expr) Error!*Expr {
        while (try p.accept(.colon2)) try p.skipType();
        return e;
    }

    fn ifExpression(p: *Parser) Error!*Expr {
        const line = p.tok.line;
        try p.advance();
        const cond = try p.expression();
        try p.expect(.then, "then");
        const then = try p.expression();
        if (p.tok.tag == .elseif) {
            return p.expr(line, .{ .ifelse = .{ .cond = cond, .then = then, .@"else" = try p.ifExpression() } });
        }
        try p.expect(.@"else", "else");
        return p.expr(line, .{ .ifelse = .{ .cond = cond, .then = then, .@"else" = try p.expression() } });
    }

    /// A backtick string: its text pieces and `{expression}`s.
    fn interp(p: *Parser) Error!*Expr {
        const line = p.tok.line;
        const raw = p.tok.text;
        var parts: std.ArrayList(*Expr) = .empty;
        var i: usize = 0;
        var piece = i;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\') {
                i += 1;
                continue;
            }
            if (raw[i] != '{') continue;
            const text = lex.unescape(p.arena, raw[piece..i]) catch return p.fail("malformed escape");
            if (text.len > 0) parts.append(p.arena, try p.expr(line, .{ .string = try p.str(text) })) catch return p.fail("out of memory");
            var depth: usize = 1;
            var j = i + 1;
            while (j < raw.len and depth > 0) : (j += 1) {
                if (raw[j] == '{') depth += 1;
                if (raw[j] == '}') depth -= 1;
            }
            if (depth != 0) return p.fail("unfinished interpolation");
            var inner = Parser.init(p.arena, p.heap, raw[i + 1 .. j - 1]);
            inner.lexer.line = line;
            inner.depth = p.depth;
            const e = inner.firstExpression() catch {
                p.err = inner.err;
                p.err_line = inner.err_line;
                return error.Syntax;
            };
            if (inner.tok.tag != .eof) return p.fail("malformed interpolation");
            parts.append(p.arena, e) catch return p.fail("out of memory");
            i = j - 1;
            piece = j;
        }
        const text = lex.unescape(p.arena, raw[piece..]) catch return p.fail("malformed escape");
        if (text.len > 0 or parts.items.len == 0) parts.append(p.arena, try p.expr(line, .{ .string = try p.str(text) })) catch return p.fail("out of memory");
        return p.expr(line, .{ .interp = parts.items });
    }

    fn primary(p: *Parser) Error!*Expr {
        const line = p.tok.line;
        if (p.tok.tag == .name) return p.expr(line, .{ .name = try p.name() });
        if (try p.accept(.lparen)) {
            const e = try p.expression();
            try p.expect(.rparen, ")");
            return p.expr(line, .{ .paren = e });
        }
        return p.fail("unexpected symbol");
    }

    fn suffixed(p: *Parser) Error!*Expr {
        var e = try p.primary();
        while (true) {
            const line = p.tok.line;
            switch (p.tok.tag) {
                .dot => {
                    try p.advance();
                    const key = try p.expr(line, .{ .string = try p.str(try p.name()) });
                    e = try p.expr(line, .{ .index = .{ .obj = e, .key = key } });
                },
                .lbracket => {
                    try p.advance();
                    const key = try p.expression();
                    try p.expect(.rbracket, "]");
                    e = try p.expr(line, .{ .index = .{ .obj = e, .key = key } });
                },
                .colon => {
                    try p.advance();
                    const m = try p.str(try p.name());
                    e = try p.expr(line, .{ .method = .{ .obj = e, .name = m, .args = try p.args() } });
                },
                .lparen, .string, .lbrace, .interp => e = try p.expr(line, .{ .call = .{ .callee = e, .args = try p.args() } }),
                else => return e,
            }
        }
    }

    fn args(p: *Parser) Error![]*Expr {
        const line = p.tok.line;
        switch (p.tok.tag) {
            .string, .interp => {
                const one = p.arena.alloc(*Expr, 1) catch return p.fail("out of memory");
                one[0] = if (p.tok.tag == .string) try p.expr(line, .{ .string = try p.str(p.tok.text) }) else try p.interp();
                try p.advance();
                return one;
            },
            .lbrace => {
                const one = p.arena.alloc(*Expr, 1) catch return p.fail("out of memory");
                one[0] = try p.table();
                return one;
            },
            .lparen => {
                try p.advance();
                if (try p.accept(.rparen)) return &.{};
                const list = try p.exprList();
                try p.expect(.rparen, ")");
                return list;
            },
            else => return p.fail("function arguments expected"),
        }
    }

    fn table(p: *Parser) Error!*Expr {
        const line = p.tok.line;
        try p.expect(.lbrace, "{");
        var fields: std.ArrayList(ast.Field) = .empty;
        while (p.tok.tag != .rbrace) {
            var f: ast.Field = undefined;
            if (p.tok.tag == .lbracket) {
                try p.advance();
                const key = try p.expression();
                try p.expect(.rbracket, "]");
                try p.expect(.eq, "=");
                f = .{ .key = key, .value = try p.expression() };
            } else if (p.tok.tag == .name and (try p.peek()).tag == .eq) {
                const key = try p.expr(p.tok.line, .{ .string = try p.str(try p.name()) });
                try p.advance();
                f = .{ .key = key, .value = try p.expression() };
            } else f = .{ .key = null, .value = try p.expression() };
            fields.append(p.arena, f) catch return p.fail("out of memory");
            if (!try p.accept(.comma) and !try p.accept(.semi)) break;
        }
        try p.expect(.rbrace, "}");
        return p.expr(line, .{ .table = fields.items });
    }

    pub const skipType = types.skipType;
    pub const skipBalanced = types.skipBalanced;
};
