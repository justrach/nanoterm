//! Luau's type annotations, read past: what they say does not change what
//! runs (`x: number?`, `(a: T) -> U`, `{ [string]: T }`, `A | B`, generics).
const std = @import("std");
const Parser = @import("parse.zig").Parser;
const Error = @import("parse.zig").Error;

pub fn skipType(p: *Parser) Error!void {
    try p.enter();
    defer p.depth -= 1;
    _ = try p.accept(.pipe);
    try skipSimpleType(p);
    while (p.tok.tag == .pipe or p.tok.tag == .amp) {
        try p.advance();
        try skipSimpleType(p);
    }
}

fn skipSimpleType(p: *Parser) Error!void {
    switch (p.tok.tag) {
        .lt => {
            try skipBalanced(p);
            return skipSimpleType(p);
        },
        .lparen => {
            try skipBalanced(p);
            if (try p.accept(.arrow)) try skipType(p);
        },
        .lbrace => try skipBalanced(p),
        .dot3 => {
            try p.advance();
            if (p.tok.tag == .name or p.tok.tag == .lparen or p.tok.tag == .lbrace) try skipSimpleType(p);
        },
        .nil, .string, .true, .false => try p.advance(),
        .name => {
            const typeof = std.mem.eql(u8, p.tok.text, "typeof");
            try p.advance();
            if (typeof and p.tok.tag == .lparen) {
                try skipBalanced(p);
            } else {
                while (try p.accept(.dot)) _ = try p.name();
                if (p.tok.tag == .lt) try skipBalanced(p);
            }
        },
        else => return p.fail("type expected"),
    }
    while (try p.accept(.question)) {}
}

/// Past a bracketed group: ( … ), { … }, [ … ] or < … >.
pub fn skipBalanced(p: *Parser) Error!void {
    var depth: usize = 0;
    while (true) {
        switch (p.tok.tag) {
            .lparen, .lbrace, .lbracket, .lt => depth += 1,
            .rparen, .rbrace, .rbracket, .gt => depth -= 1,
            .eof => return p.fail("unbalanced brackets"),
            else => {},
        }
        try p.advance();
        if (depth == 0) return;
    }
}
