//! The syntax tree the parser builds and the interpreter walks. Names are
//! resolved after parsing (resolve.zig): each becomes a local, found so many
//! scopes up at a slot, or a global.
const value = @import("value.zig");
const Str = value.Str;

pub const BinOp = enum { add, sub, mul, div, idiv, mod, pow, concat, eq, ne, lt, le, gt, ge, @"and", @"or" };
pub const UnOp = enum { neg, not, len };

/// A local: `hops` scopes (that have locals) up, at `slot`.
pub const Slot = struct { hops: u16, slot: u16 };

pub const Field = struct {
    /// Null for a positional value (`{a, b}`).
    key: ?*Expr,
    value: *Expr,
};

pub const Expr = struct {
    line: u32,
    kind: union(enum) {
        nil,
        true,
        false,
        number: f64,
        string: *Str,
        /// Before resolving.
        name: []const u8,
        local: Slot,
        global: *Str,
        index: struct { obj: *Expr, key: *Expr },
        call: struct { callee: *Expr, args: []*Expr },
        method: struct { obj: *Expr, name: *Str, args: []*Expr },
        function: *Func,
        table: []Field,
        binary: struct { op: BinOp, l: *Expr, r: *Expr },
        unary: struct { op: UnOp, e: *Expr },
        /// Luau's `if c then a else b`.
        ifelse: struct { cond: *Expr, then: *Expr, @"else": *Expr },
        /// Luau's `` `a {b} c` ``: strings and expressions in turn.
        interp: []*Expr,
        /// `(e)`: one value of a call.
        paren: *Expr,
        /// `...` before resolving, then where the extra arguments are.
        vararg: ?Slot,
    },

    pub fn multi(e: *const Expr) bool {
        return e.kind == .call or e.kind == .method or e.kind == .vararg;
    }
};

pub const Block = struct {
    stmts: []Stmt,
    /// The locals declared in this scope; 0 makes no scope at run time.
    slots: u16 = 0,
};

pub const Func = struct {
    /// With a last "..." when it takes extra arguments.
    params: []const []const u8,
    body: *Block,
    name: []const u8,
    line: u32,
};

pub const Stmt = struct {
    line: u32,
    kind: union(enum) {
        local: struct { names: []const []const u8, slots: []u16, values: []*Expr },
        local_function: struct { name: []const u8, slot: u16 = 0, func: *Func },
        assign: struct { targets: []*Expr, values: []*Expr },
        compound: struct { op: BinOp, target: *Expr, value: *Expr },
        call: *Expr,
        do: *Block,
        @"while": struct { cond: *Expr, body: *Block },
        repeat: struct { body: *Block, cond: *Expr },
        @"if": struct { conds: []*Expr, blocks: []*Block, @"else": ?*Block },
        /// The variable is slot 0 of the body's scope.
        numeric_for: struct { name: []const u8, start: *Expr, limit: *Expr, step: ?*Expr, body: *Block },
        /// The variables are slots 0… of the body's scope.
        generic_for: struct { names: []const []const u8, exprs: []*Expr, body: *Block },
        @"return": []*Expr,
        @"break",
        @"continue",
    },
};
