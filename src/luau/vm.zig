//! The interpreter: walks the syntax tree with a value stack of fixed size
//! (slices of it stay valid), a step budget and a memory budget. Locals live
//! in scopes on the heap, so closures keep what they see, loop by loop.
//! Nothing here reaches files, processes, the network or the clock.
const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");
const ops = @import("ops.zig");
const parse = @import("parse.zig");
const resolve = @import("resolve.zig");
const Value = value.Value;
const Env = value.Env;
pub const Error = value.Error;

const Flow = enum { normal, @"break", @"continue", @"return" };

pub const Options = struct {
    /// Statements, loop turns and calls per top-level call.
    steps: u64 = 400_000,
    memory: usize = 16 * 1024 * 1024,
    stack: usize = 1 << 15,
    depth: u32 = 160,
};

pub const Vm = struct {
    gpa: std.mem.Allocator,
    heap: value.Heap,
    /// The syntax trees of what was loaded.
    trees: std.heap.ArenaAllocator,
    globals: *value.Table,
    /// Where `s:upper()` and the like are found.
    strings: ?*value.Table = null,
    stack: []Value,
    top: usize = 0,
    steps: u64 = 0,
    options: Options,
    depth: u32 = 0,
    line: u32 = 0,
    /// Where a `return` left its values on the stack.
    ret_base: usize = 0,
    /// The value of the last error (a message, or what `error` was given).
    err_value: Value = .nil,
    /// The message of an error that is not a value (budget, memory, syntax).
    err_text: []const u8 = "",
    err_buf: [256]u8 = undefined,
    rets: [8]Value = undefined,
    /// The value the native running keeps (see value.Function).
    bound: Value = .nil,

    pub fn create(gpa: std.mem.Allocator, options: Options) !*Vm {
        const vm = try gpa.create(Vm);
        errdefer gpa.destroy(vm);
        const stack = try gpa.alloc(Value, options.stack);
        vm.* = .{ .gpa = gpa, .heap = .{ .gpa = gpa, .limit = options.memory }, .trees = .init(gpa), .globals = undefined, .stack = stack, .options = options };
        vm.globals = try vm.heap.table();
        vm.globals.obj.fixed = true;
        return vm;
    }

    pub fn destroy(vm: *Vm) void {
        vm.heap.deinit();
        vm.trees.deinit();
        vm.gpa.free(vm.stack);
        vm.gpa.destroy(vm);
    }

    /// The error's message, for the host.
    pub fn message(vm: *Vm) []const u8 {
        if (vm.err_text.len > 0) return vm.err_text;
        return switch (vm.err_value) {
            .string => |s| s.bytes,
            .nil => "error",
            else => |v| ops.toText(&vm.err_buf, v),
        };
    }

    /// Compiles `src` to a function of no arguments.
    pub fn load(vm: *Vm, name: []const u8, src: []const u8) Error!Value {
        const arena = vm.trees.allocator();
        var p = parse.Parser.init(arena, &vm.heap, src);
        const f = p.chunk() catch return vm.syntax(name, p.err, p.err_line);
        var r: resolve.Resolver = .{ .arena = arena, .heap = &vm.heap };
        r.func(f) catch return vm.syntax(name, r.err, r.err_line);
        const fun = try vm.heap.function(.{ .kind = .{ .closure = .{ .proto = f, .env = null } } });
        return .{ .function = fun };
    }

    fn syntax(vm: *Vm, name: []const u8, msg: []const u8, line: u32) Error {
        vm.err_text = std.fmt.bufPrint(&vm.err_buf, "{s}:{d}: {s}", .{ name, line, msg }) catch "syntax error";
        return error.Runtime;
    }

    /// Results for a native to return: valid until the next native returns.
    pub fn ret(vm: *Vm, values: []const Value) []const Value {
        @memcpy(vm.rets[0..values.len], values);
        return vm.rets[0..values.len];
    }

    /// Calls `f` from the host with a fresh budget. The results stay valid
    /// until the next call.
    pub fn callTop(vm: *Vm, f: Value, args: []const Value) Error![]const Value {
        vm.top = 0;
        vm.steps = 0;
        vm.depth = 0;
        vm.err_value = .nil;
        vm.err_text = "";
        for (args) |a| try vm.push(a);
        const n = vm.call(f, 0) catch |e| {
            if (e == error.Memory) vm.err_text = "visual exceeded its memory budget";
            return e;
        };
        return vm.stack[0..n];
    }

    /// Frees what nothing reaches: `roots`, the globals and what is fixed.
    pub fn collect(vm: *Vm, roots: []const Value) void {
        vm.top = 0;
        for (roots) |r| vm.heap.mark(r);
        vm.heap.mark(vm.err_value);
        vm.heap.sweep();
    }

    pub fn fail(vm: *Vm, comptime fmt: []const u8, args: anytype) Error {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "visual:{d}: " ++ fmt, .{vm.line} ++ args) catch "visual: error";
        const s = vm.heap.str(msg) catch return error.Memory;
        vm.err_value = .{ .string = s };
        return error.Runtime;
    }

    pub fn tick(vm: *Vm) Error!void {
        vm.steps += 1;
        if (vm.steps > vm.options.steps) {
            vm.err_text = "visual execution exceeded its budget";
            return error.Budget;
        }
    }

    pub fn push(vm: *Vm, v: Value) Error!void {
        if (vm.top >= vm.stack.len) return vm.fail("stack overflow", .{});
        vm.stack[vm.top] = v;
        vm.top += 1;
    }

    /// Calls `f` with the arguments at stack[base..top]; its results end up
    /// at stack[base..], top just past them. Returns how many.
    pub fn call(vm: *Vm, f: Value, base: usize) Error!usize {
        try vm.tick();
        if (f != .function) return vm.fail("attempt to call a {s} value", .{f.typeName()});
        vm.depth += 1;
        defer vm.depth -= 1;
        if (vm.depth > vm.options.depth) return vm.fail("stack overflow", .{});
        const args = vm.stack[base..vm.top];
        switch (f.function.kind) {
            .native => |n| {
                vm.bound = n.bound;
                const out = try n.f(vm, args);
                std.mem.copyForwards(Value, vm.stack[base .. base + out.len], out);
                vm.top = base + out.len;
                return out.len;
            },
            .closure => |c| {
                const b = c.proto.body;
                const env = if (b.slots > 0) try vm.heap.env(c.env, b.slots) else c.env;
                const params = c.proto.params;
                const vararg = params.len > 0 and params[params.len - 1][0] == '.';
                const fixed = if (vararg) params.len - 1 else params.len;
                for (0..fixed) |i| env.?.slots[i] = if (i < args.len) args[i] else .nil;
                if (vararg) {
                    const t = try vm.heap.table();
                    var i: usize = fixed;
                    while (i < args.len) : (i += 1) try vm.heap.set(t, .{ .number = @floatFromInt(i - fixed + 1) }, args[i]);
                    env.?.slots[fixed] = .{ .table = t };
                }
                vm.top = base;
                const flow = try vm.stmts(b.stmts, env);
                if (flow != .@"return") {
                    vm.top = base;
                    return 0;
                }
                const n = vm.top - vm.ret_base;
                std.mem.copyForwards(Value, vm.stack[base .. base + n], vm.stack[vm.ret_base..vm.top]);
                vm.top = base + n;
                return n;
            },
        }
    }

    /// Calls `f` with `args` and gives its first result (for natives).
    pub fn call1(vm: *Vm, f: Value, args: []const Value) Error!Value {
        const base = vm.top;
        for (args) |a| try vm.push(a);
        const n = try vm.call(f, base);
        const r = if (n > 0) vm.stack[base] else .nil;
        vm.top = base;
        return r;
    }

    fn local(env: ?*Env, s: ast.Slot) *Value {
        var e = env.?;
        var h = s.hops;
        while (h > 0) : (h -= 1) e = e.parent.?;
        return &e.slots[s.slot];
    }

    fn block(vm: *Vm, b: *const ast.Block, env: ?*Env) Error!Flow {
        const scope = if (b.slots > 0) try vm.heap.env(env, b.slots) else env;
        return vm.stmts(b.stmts, scope);
    }

    fn stmts(vm: *Vm, list: []const ast.Stmt, env: ?*Env) Error!Flow {
        for (list) |*s| {
            const flow = try vm.stmt(s, env);
            if (flow != .normal) return flow;
        }
        return .normal;
    }

    fn stmt(vm: *Vm, s: *const ast.Stmt, env: ?*Env) Error!Flow {
        try vm.tick();
        vm.line = s.line;
        switch (s.kind) {
            .local => |l| {
                const base = vm.top;
                try vm.pushList(l.values, env, l.names.len);
                for (l.slots, 0..) |slot, i| env.?.slots[slot] = vm.stack[base + i];
                vm.top = base;
            },
            .local_function => |l| {
                env.?.slots[l.slot] = .{ .function = try vm.closure(l.func, env) };
            },
            .assign => |a| {
                const base = vm.top;
                try vm.pushList(a.values, env, a.targets.len);
                for (a.targets, 0..) |t, i| try vm.assign(t, vm.stack[base + i], env);
                vm.top = base;
            },
            .compound => |c| {
                // The target's object and key are found once.
                var obj: Value = .nil;
                var key: Value = .nil;
                const old = switch (c.target.kind) {
                    .index => |x| blk: {
                        obj = try vm.eval(x.obj, env);
                        key = try vm.eval(x.key, env);
                        break :blk try vm.index(obj, key);
                    },
                    else => try vm.eval(c.target, env),
                };
                const new = try vm.binary(c.op, old, try vm.eval(c.value, env));
                switch (c.target.kind) {
                    .index => try vm.setIndex(obj, key, new),
                    else => try vm.assign(c.target, new, env),
                }
            },
            .call => |e| {
                const base = vm.top;
                try vm.pushMulti(e, env);
                vm.top = base;
            },
            .do => |b| return vm.block(b, env),
            .@"while" => |w| while ((try vm.eval(w.cond, env)).truthy()) {
                try vm.tick();
                switch (try vm.block(w.body, env)) {
                    .@"break" => break,
                    .@"return" => return .@"return",
                    else => {},
                }
            },
            .repeat => |r| while (true) {
                try vm.tick();
                const scope = if (r.body.slots > 0) try vm.heap.env(env, r.body.slots) else env;
                switch (try vm.stmts(r.body.stmts, scope)) {
                    .@"break" => break,
                    .@"return" => return .@"return",
                    else => {},
                }
                if ((try vm.eval(r.cond, scope)).truthy()) break;
            },
            .@"if" => |f| {
                for (f.conds, f.blocks) |cond, b| if ((try vm.eval(cond, env)).truthy()) return vm.block(b, env);
                if (f.@"else") |b| return vm.block(b, env);
            },
            .numeric_for => |f| return vm.numericFor(f.start, f.limit, f.step, f.body, env),
            .generic_for => |f| return vm.genericFor(f.exprs, f.body, f.names.len, env),
            .@"return" => |list| {
                // Calls in the list return too: set where ours start last.
                const base = vm.top;
                try vm.pushList(list, env, null);
                vm.ret_base = base;
                return .@"return";
            },
            .@"break" => return .@"break",
            .@"continue" => return .@"continue",
        }
        return .normal;
    }

    fn numericFor(vm: *Vm, start_e: *ast.Expr, limit_e: *ast.Expr, step_e: ?*ast.Expr, body: *const ast.Block, env: ?*Env) Error!Flow {
        const start = ops.toNumber(try vm.eval(start_e, env)) orelse return vm.fail("'for' initial value must be a number", .{});
        const limit = ops.toNumber(try vm.eval(limit_e, env)) orelse return vm.fail("'for' limit must be a number", .{});
        const step = if (step_e) |e| ops.toNumber(try vm.eval(e, env)) orelse return vm.fail("'for' step must be a number", .{}) else 1;
        if (step == 0) return vm.fail("'for' step is zero", .{});
        var i = start;
        while (if (step > 0) i <= limit else i >= limit) : (i += step) {
            try vm.tick();
            const scope = try vm.heap.env(env, body.slots);
            scope.slots[0] = .{ .number = i };
            switch (try vm.stmts(body.stmts, scope)) {
                .@"break" => break,
                .@"return" => return .@"return",
                else => {},
            }
        }
        return .normal;
    }

    fn genericFor(vm: *Vm, exprs: []*ast.Expr, body: *const ast.Block, nvars: usize, env: ?*Env) Error!Flow {
        const base = vm.top;
        try vm.pushList(exprs, env, 3);
        const f = vm.stack[base];
        const state = vm.stack[base + 1];
        var control = vm.stack[base + 2];
        vm.top = base;
        // Luau iterates a table itself: `for k, v in t do`.
        if (f == .table) {
            var key: Value = .nil;
            while (try next(vm, f.table, key)) |kv| {
                try vm.tick();
                key = kv[0];
                const scope = try vm.heap.env(env, body.slots);
                scope.slots[0] = kv[0];
                if (nvars > 1) scope.slots[1] = kv[1];
                switch (try vm.stmts(body.stmts, scope)) {
                    .@"break" => break,
                    .@"return" => return .@"return",
                    else => {},
                }
            }
            return .normal;
        }
        while (true) {
            try vm.tick();
            try vm.push(state);
            try vm.push(control);
            const n = try vm.call(f, base);
            const scope = try vm.heap.env(env, body.slots);
            for (0..nvars) |i| scope.slots[i] = if (i < n) vm.stack[base + i] else .nil;
            vm.top = base;
            if (scope.slots[0] == .nil) break;
            control = scope.slots[0];
            switch (try vm.stmts(body.stmts, scope)) {
                .@"break" => break,
                .@"return" => return .@"return",
                else => {},
            }
        }
        return .normal;
    }

    fn closure(vm: *Vm, f: *const ast.Func, env: ?*Env) Error!*value.Function {
        return vm.heap.function(.{ .kind = .{ .closure = .{ .proto = f, .env = env } } });
    }

    fn assign(vm: *Vm, target: *const ast.Expr, v: Value, env: ?*Env) Error!void {
        switch (target.kind) {
            .local => |s| local(env, s).* = v,
            .global => |name| try vm.heap.set(vm.globals, .{ .string = name }, v),
            .index => |x| try vm.setIndex(try vm.eval(x.obj, env), try vm.eval(x.key, env), v),
            else => return vm.fail("cannot assign", .{}),
        }
    }

    pub fn setIndex(vm: *Vm, obj: Value, key: Value, v: Value) Error!void {
        if (obj != .table) return vm.fail("attempt to index {s} with {s}", .{ obj.typeName(), keyText(key) });
        if (key == .nil) return vm.fail("table index is nil", .{});
        if (key == .number and std.math.isNan(key.number)) return vm.fail("table index is NaN", .{});
        try vm.heap.set(obj.table, key, v);
    }

    pub fn index(vm: *Vm, obj: Value, key: Value) Error!Value {
        return switch (obj) {
            .table => |t| t.get(key),
            .string => if (vm.strings) |s| s.get(key) else .nil,
            else => vm.fail("attempt to index {s} with {s}", .{ obj.typeName(), keyText(key) }),
        };
    }

    fn keyText(k: Value) []const u8 {
        return switch (k) {
            .string => |s| s.bytes,
            else => k.typeName(),
        };
    }

    /// Pushes the values of `list`, the last one's all; then pads or cuts
    /// to `want` values when given.
    fn pushList(vm: *Vm, list: []const *ast.Expr, env: ?*Env, want: ?usize) Error!void {
        const base = vm.top;
        for (list, 0..) |e, i| {
            if (i == list.len - 1 and e.multi()) try vm.pushMulti(e, env) else try vm.push(try vm.eval(e, env));
        }
        if (want) |n| {
            while (vm.top < base + n) try vm.push(.nil);
            vm.top = base + n;
        }
    }

    /// Pushes every value of a call or `...`.
    fn pushMulti(vm: *Vm, e: *const ast.Expr, env: ?*Env) Error!void {
        const base = vm.top;
        switch (e.kind) {
            .call => |c| {
                const f = try vm.eval(c.callee, env);
                try vm.pushList(c.args, env, null);
                vm.line = e.line;
                _ = try vm.call(f, base);
            },
            .method => |m| {
                const obj = try vm.eval(m.obj, env);
                vm.line = e.line;
                const f = try vm.index(obj, .{ .string = m.name });
                if (f == .nil) return vm.fail("attempt to call missing method '{s}' of {s}", .{ m.name.bytes, obj.typeName() });
                try vm.push(obj);
                try vm.pushList(m.args, env, null);
                _ = try vm.call(f, base);
            },
            .vararg => |s| {
                const t = local(env, s.?).*.table;
                for (t.array.items) |v| try vm.push(v);
            },
            else => try vm.push(try vm.eval(e, env)),
        }
    }

    pub fn eval(vm: *Vm, e: *const ast.Expr, env: ?*Env) Error!Value {
        switch (e.kind) {
            .nil => return .nil,
            .true => return .{ .boolean = true },
            .false => return .{ .boolean = false },
            .number => |n| return .{ .number = n },
            .string => |s| return .{ .string = s },
            .local => |s| return local(env, s).*,
            .global => |name| return vm.globals.get(.{ .string = name }),
            .name => unreachable,
            .index => |x| {
                const obj = try vm.eval(x.obj, env);
                const key = try vm.eval(x.key, env);
                vm.line = e.line;
                return vm.index(obj, key);
            },
            .call, .method, .vararg => {
                const base = vm.top;
                try vm.pushMulti(e, env);
                const v = if (vm.top > base) vm.stack[base] else .nil;
                vm.top = base;
                return v;
            },
            .paren => |x| return vm.eval(x, env),
            .function => |f| return .{ .function = try vm.closure(f, env) },
            .table => |fields| return vm.table(fields, env),
            .binary => |b| {
                const l = try vm.eval(b.l, env);
                switch (b.op) {
                    .@"and" => return if (!l.truthy()) l else vm.eval(b.r, env),
                    .@"or" => return if (l.truthy()) l else vm.eval(b.r, env),
                    else => {},
                }
                const r = try vm.eval(b.r, env);
                vm.line = e.line;
                return vm.binary(b.op, l, r);
            },
            .unary => |u| {
                const v = try vm.eval(u.e, env);
                vm.line = e.line;
                return switch (u.op) {
                    .not => .{ .boolean = !v.truthy() },
                    .neg => .{ .number = -(ops.toNumber(v) orelse return vm.fail("attempt to perform arithmetic (unm) on {s}", .{v.typeName()})) },
                    .len => switch (v) {
                        .string => |s| .{ .number = @floatFromInt(s.bytes.len) },
                        .table => |t| .{ .number = @floatFromInt(t.len()) },
                        else => vm.fail("attempt to get length of a {s} value", .{v.typeName()}),
                    },
                };
            },
            .ifelse => |x| return if ((try vm.eval(x.cond, env)).truthy()) vm.eval(x.then, env) else vm.eval(x.@"else", env),
            .interp => |parts| {
                var out: std.ArrayList(u8) = .empty;
                errdefer out.deinit(vm.gpa);
                var buf: [64]u8 = undefined;
                for (parts) |p| {
                    const v = try vm.eval(p, env);
                    const text = try vm.tostring(&buf, v);
                    out.appendSlice(vm.gpa, text) catch return error.Memory;
                }
                return .{ .string = try vm.heap.strOwned(out.toOwnedSlice(vm.gpa) catch return error.Memory) };
            },
        }
    }

    /// `tostring(v)`, including what a `__tostring`-less table prints.
    pub fn tostring(_: *Vm, buf: []u8, v: Value) Error![]const u8 {
        return ops.toText(buf, v);
    }

    fn table(vm: *Vm, fields: []const ast.Field, env: ?*Env) Error!Value {
        const t = try vm.heap.table();
        var n: f64 = 1;
        for (fields, 0..) |f, i| {
            if (f.key) |k| {
                const key = try vm.eval(k, env);
                if (key == .nil) return vm.fail("table index is nil", .{});
                try vm.heap.set(t, key, try vm.eval(f.value, env));
            } else if (i == fields.len - 1 and f.value.multi()) {
                const base = vm.top;
                try vm.pushMulti(f.value, env);
                for (vm.stack[base..vm.top]) |v| {
                    try vm.heap.set(t, .{ .number = n }, v);
                    n += 1;
                }
                vm.top = base;
            } else {
                try vm.heap.set(t, .{ .number = n }, try vm.eval(f.value, env));
                n += 1;
            }
        }
        return .{ .table = t };
    }

    pub fn binary(vm: *Vm, op: ast.BinOp, l: Value, r: Value) Error!Value {
        switch (op) {
            .eq => return .{ .boolean = l.eql(r) },
            .ne => return .{ .boolean = !l.eql(r) },
            .lt, .le => return .{ .boolean = ops.less(l, r, op == .le) orelse return vm.compareError(op, l, r) },
            .gt, .ge => return .{ .boolean = ops.less(r, l, op == .ge) orelse return vm.compareError(op, l, r) },
            .concat => {
                if ((l != .string and l != .number) or (r != .string and r != .number))
                    return vm.fail("attempt to concatenate {s} with {s}", .{ l.typeName(), r.typeName() });
                var b1: [64]u8 = undefined;
                var b2: [64]u8 = undefined;
                const a = ops.toText(&b1, l);
                const b = ops.toText(&b2, r);
                const out = vm.gpa.alloc(u8, a.len + b.len) catch return error.Memory;
                @memcpy(out[0..a.len], a);
                @memcpy(out[a.len..], b);
                return .{ .string = try vm.heap.strOwned(out) };
            },
            else => {
                const a = ops.toNumber(l) orelse return vm.fail("attempt to perform arithmetic ({s}) on {s}", .{ ops.opName(op), l.typeName() });
                const b = ops.toNumber(r) orelse return vm.fail("attempt to perform arithmetic ({s}) on {s}", .{ ops.opName(op), r.typeName() });
                return .{ .number = ops.arith(op, a, b) };
            },
        }
    }

    fn compareError(vm: *Vm, op: ast.BinOp, l: Value, r: Value) Error {
        return vm.fail("attempt to compare {s} {s} {s}", .{ l.typeName(), ops.opName(op), r.typeName() });
    }
};

/// The entry after `key` in `t` (array part, then the rest in order), or
/// null at the end.
pub fn next(vm: *Vm, t: *value.Table, key: Value) Error!?[2]Value {
    var i: usize = 0;
    if (key != .nil) {
        if (key == .number and key.number >= 1 and key.number == @floor(key.number) and key.number <= @as(f64, @floatFromInt(t.array.items.len))) {
            i = @intFromFloat(key.number);
        } else {
            const at = t.hash.getIndex(key) orelse return vm.fail("invalid key to 'next'", .{});
            i = t.array.items.len + at + 1;
        }
    }
    while (i < t.array.items.len) : (i += 1) {
        if (t.array.items[i] != .nil) return .{ .{ .number = @floatFromInt(i + 1) }, t.array.items[i] };
    }
    const h = i - t.array.items.len;
    if (h < t.hash.count()) return .{ t.hash.keys()[h], t.hash.values()[h] };
    return null;
}
