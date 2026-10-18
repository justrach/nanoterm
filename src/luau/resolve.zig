//! Names to places, once after parsing: each name becomes a local (so many
//! scopes up, at a slot) or a global. A scope declares its locals in slots
//! in order; one with none makes no scope at run time and is not counted.
const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");

pub const Error = error{Syntax};

const Scope = struct {
    names: std.ArrayList([]const u8) = .empty,
    /// Whether it makes a scope at run time.
    real: bool,
};

pub const Resolver = struct {
    arena: std.mem.Allocator,
    heap: *value.Heap,
    scopes: std.ArrayList(Scope) = .empty,
    err: []const u8 = "",
    err_line: u32 = 0,

    pub fn func(r: *Resolver, f: *ast.Func) Error!void {
        try r.body(f.body, f.params);
    }

    fn fail(r: *Resolver, line: u32, msg: []const u8) Error {
        r.err = msg;
        r.err_line = line;
        return error.Syntax;
    }

    /// How many locals `b` declares itself, besides `implicit` ones.
    fn count(b: *const ast.Block, implicit: usize) usize {
        var n = implicit;
        for (b.stmts) |s| switch (s.kind) {
            .local => |l| n += l.names.len,
            .local_function => n += 1,
            else => {},
        };
        return n;
    }

    /// Opens `b`'s scope with `implicit` names declared first, and resolves
    /// its statements. The caller closes it (repeat's condition is inside).
    fn open(r: *Resolver, b: *ast.Block, implicit: []const []const u8) Error!void {
        const n = count(b, implicit.len);
        if (n > std.math.maxInt(u16)) return r.fail(0, "too many locals");
        b.slots = @intCast(n);
        r.scopes.append(r.arena, .{ .real = n > 0 }) catch return r.fail(0, "out of memory");
        for (implicit) |name| _ = try r.declare(name);
        for (b.stmts) |*s| try r.stmt(s);
    }

    fn close(r: *Resolver) void {
        _ = r.scopes.pop();
    }

    fn body(r: *Resolver, b: *ast.Block, implicit: []const []const u8) Error!void {
        try r.open(b, implicit);
        r.close();
    }

    fn declare(r: *Resolver, name: []const u8) Error!u16 {
        const s = &r.scopes.items[r.scopes.items.len - 1];
        s.names.append(r.arena, name) catch return r.fail(0, "out of memory");
        return @intCast(s.names.items.len - 1);
    }

    fn lookup(r: *Resolver, name: []const u8) ?ast.Slot {
        var hops: u16 = 0;
        var i = r.scopes.items.len;
        while (i > 0) {
            i -= 1;
            const s = r.scopes.items[i];
            var j = s.names.items.len;
            while (j > 0) {
                j -= 1;
                if (std.mem.eql(u8, s.names.items[j], name)) return .{ .hops = hops, .slot = @intCast(j) };
            }
            if (s.real) hops += 1;
        }
        return null;
    }

    fn stmt(r: *Resolver, s: *ast.Stmt) Error!void {
        switch (s.kind) {
            .local => |*l| {
                for (l.values) |e| try r.expr(e);
                for (l.names, 0..) |n, i| l.slots[i] = try r.declare(n);
            },
            .local_function => |*l| {
                l.slot = try r.declare(l.name);
                try r.func(l.func);
            },
            .assign => |a| {
                for (a.values) |e| try r.expr(e);
                for (a.targets) |e| try r.expr(e);
            },
            .compound => |c| {
                try r.expr(c.value);
                try r.expr(c.target);
            },
            .call => |e| try r.expr(e),
            .do => |b| try r.body(b, &.{}),
            .@"while" => |w| {
                try r.expr(w.cond);
                try r.body(w.body, &.{});
            },
            .repeat => |rp| {
                try r.open(rp.body, &.{});
                try r.expr(rp.cond);
                r.close();
            },
            .@"if" => |f| {
                for (f.conds) |e| try r.expr(e);
                for (f.blocks) |b| try r.body(b, &.{});
                if (f.@"else") |b| try r.body(b, &.{});
            },
            .numeric_for => |f| {
                try r.expr(f.start);
                try r.expr(f.limit);
                if (f.step) |e| try r.expr(e);
                try r.body(f.body, &.{f.name});
            },
            .generic_for => |f| {
                for (f.exprs) |e| try r.expr(e);
                try r.body(f.body, f.names);
            },
            .@"return" => |list| for (list) |e| try r.expr(e),
            .@"break", .@"continue" => {},
        }
    }

    fn expr(r: *Resolver, e: *ast.Expr) Error!void {
        switch (e.kind) {
            .name => |n| {
                if (r.lookup(n)) |slot| {
                    e.kind = .{ .local = slot };
                } else {
                    const s = r.heap.str(n) catch return r.fail(e.line, "out of memory");
                    s.obj.fixed = true;
                    e.kind = .{ .global = s };
                }
            },
            .vararg => e.kind = .{ .vararg = r.lookup("...") orelse return r.fail(e.line, "cannot use '...' outside a vararg function") },
            .index => |x| {
                try r.expr(x.obj);
                try r.expr(x.key);
            },
            .call => |c| {
                try r.expr(c.callee);
                for (c.args) |a| try r.expr(a);
            },
            .method => |m| {
                try r.expr(m.obj);
                for (m.args) |a| try r.expr(a);
            },
            .function => |f| try r.func(f),
            .table => |fields| for (fields) |f| {
                if (f.key) |k| try r.expr(k);
                try r.expr(f.value);
            },
            .binary => |b| {
                try r.expr(b.l);
                try r.expr(b.r);
            },
            .unary => |u| try r.expr(u.e),
            .ifelse => |x| {
                try r.expr(x.cond);
                try r.expr(x.then);
                try r.expr(x.@"else");
            },
            .interp => |parts| for (parts) |p| try r.expr(p),
            .paren => |x| try r.expr(x),
            .nil, .true, .false, .number, .string, .local, .global => {},
        }
    }
};
