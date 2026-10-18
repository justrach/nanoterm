//! Luau's values and the heap they live on: strings, tables, functions and
//! the scopes closures keep. Every object is counted against a memory budget
//! and collected (mark and sweep) only between calls, when the roots are
//! known: the globals, what the host holds, and what is fixed (constants,
//! libraries).
const std = @import("std");
const ast = @import("ast.zig");

pub const Error = error{ Runtime, Budget, Memory };

pub const Value = union(enum) {
    nil,
    boolean: bool,
    number: f64,
    string: *Str,
    table: *Table,
    function: *Function,

    pub fn truthy(v: Value) bool {
        return switch (v) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }

    pub fn typeName(v: Value) []const u8 {
        return switch (v) {
            .nil => "nil",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .table => "table",
            .function => "function",
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .nil => b == .nil,
            .boolean => |x| b == .boolean and b.boolean == x,
            .number => |x| b == .number and b.number == x,
            .string => |x| b == .string and std.mem.eql(u8, x.bytes, b.string.bytes),
            .table => |x| b == .table and b.table == x,
            .function => |x| b == .function and b.function == x,
        };
    }
};

pub const Obj = struct {
    kind: enum { str, table, function, env },
    marked: bool = false,
    /// Never collected: constants and libraries.
    fixed: bool = false,
    next: ?*Obj = null,
};

pub const Str = struct {
    obj: Obj = .{ .kind = .str },
    bytes: []const u8,
};

const KeyContext = struct {
    pub fn hash(_: KeyContext, k: Value) u32 {
        return switch (k) {
            .nil => 0,
            .boolean => |b| @intFromBool(b) + 1,
            .number => |n| @truncate(std.hash.Wyhash.hash(1, std.mem.asBytes(&(if (n == 0) @as(f64, 0) else n)))),
            .string => |s| @truncate(std.hash.Wyhash.hash(2, s.bytes)),
            .table => |t| @truncate(std.hash.Wyhash.hash(3, std.mem.asBytes(&t))),
            .function => |f| @truncate(std.hash.Wyhash.hash(4, std.mem.asBytes(&f))),
        };
    }
    pub fn eql(_: KeyContext, a: Value, b: Value, _: usize) bool {
        return a.eql(b);
    }
};

/// A table: values at 1…n in `array`, every other key in `hash`, which
/// keeps the order keys were added in (so `pairs` is deterministic).
pub const Table = struct {
    obj: Obj = .{ .kind = .table },
    array: std.ArrayList(Value) = .empty,
    hash: std.ArrayHashMapUnmanaged(Value, Value, KeyContext, true) = .empty,

    fn arrayIndex(t: *const Table, k: Value) ?usize {
        if (k != .number) return null;
        const n = k.number;
        if (n < 1 or n != @floor(n) or n > @as(f64, @floatFromInt(t.array.items.len + 1))) return null;
        return @as(usize, @intFromFloat(n)) - 1;
    }

    pub fn get(t: *const Table, k: Value) Value {
        if (t.arrayIndex(k)) |i| if (i < t.array.items.len) return t.array.items[i];
        return t.hash.get(k) orelse .nil;
    }

    pub fn getStr(t: *const Table, name: []const u8) Value {
        var s: Str = .{ .bytes = name };
        return t.get(.{ .string = &s });
    }

    /// The length operator: a border of the array part.
    pub fn len(t: *const Table) usize {
        return t.array.items.len;
    }
};

pub const NativeFn = *const fn (vm: *anyopaque, args: []const Value) Error![]const Value;

pub const Function = struct {
    obj: Obj = .{ .kind = .function },
    kind: union(enum) {
        closure: struct { proto: *const ast.Func, env: ?*Env },
        /// `bound` is a value the native keeps (vm.bound while it runs).
        native: struct { f: NativeFn, name: []const u8, bound: Value = .nil },
    },
};

/// One scope's locals, kept while a closure can still see them.
pub const Env = struct {
    obj: Obj = .{ .kind = .env },
    parent: ?*Env,
    slots: []Value,
};

pub const Heap = struct {
    gpa: std.mem.Allocator,
    objects: ?*Obj = null,
    bytes: usize = 0,
    limit: usize,
    /// Bytes live after the last collection: the next comes at twice that.
    live: usize = 0,
    grays: std.ArrayList(*Obj) = .empty,
    /// Marking ran out of memory: keep everything this time.
    lost: bool = false,

    pub fn deinit(h: *Heap) void {
        var o = h.objects;
        while (o) |obj| {
            o = obj.next;
            h.free(obj);
        }
        h.objects = null;
        h.grays.deinit(h.gpa);
    }

    fn charge(h: *Heap, n: usize) Error!void {
        if (h.bytes + n > h.limit) return error.Memory;
        h.bytes += n;
    }

    fn link(h: *Heap, o: *Obj) void {
        o.next = h.objects;
        h.objects = o;
    }

    pub fn str(h: *Heap, bytes: []const u8) Error!*Str {
        try h.charge(@sizeOf(Str) + bytes.len);
        const s = h.gpa.create(Str) catch return error.Memory;
        s.* = .{ .bytes = h.gpa.dupe(u8, bytes) catch {
            h.gpa.destroy(s);
            return error.Memory;
        } };
        h.link(&s.obj);
        return s;
    }

    /// A string that takes `bytes`, allocated with the heap's allocator.
    pub fn strOwned(h: *Heap, bytes: []u8) Error!*Str {
        h.charge(@sizeOf(Str) + bytes.len) catch |e| {
            h.gpa.free(bytes);
            return e;
        };
        const s = h.gpa.create(Str) catch return error.Memory;
        s.* = .{ .bytes = bytes };
        h.link(&s.obj);
        return s;
    }

    pub fn table(h: *Heap) Error!*Table {
        try h.charge(@sizeOf(Table));
        const t = h.gpa.create(Table) catch return error.Memory;
        t.* = .{};
        h.link(&t.obj);
        return t;
    }

    pub fn function(h: *Heap, f: Function) Error!*Function {
        try h.charge(@sizeOf(Function));
        const p = h.gpa.create(Function) catch return error.Memory;
        p.* = f;
        p.obj = .{ .kind = .function };
        h.link(&p.obj);
        return p;
    }

    pub fn native(h: *Heap, name: []const u8, f: NativeFn) Error!*Function {
        return h.function(.{ .kind = .{ .native = .{ .f = f, .name = name } } });
    }

    pub fn env(h: *Heap, parent: ?*Env, n: usize) Error!*Env {
        try h.charge(@sizeOf(Env) + n * @sizeOf(Value));
        const e = h.gpa.create(Env) catch return error.Memory;
        const slots = h.gpa.alloc(Value, n) catch {
            h.gpa.destroy(e);
            return error.Memory;
        };
        @memset(slots, .nil);
        e.* = .{ .parent = parent, .slots = slots };
        h.link(&e.obj);
        return e;
    }

    /// Sets `t[k] = v`, moving keys into the array part as it grows.
    pub fn set(h: *Heap, t: *Table, k: Value, v: Value) Error!void {
        switch (k) {
            .nil => return error.Runtime,
            .number => |n| if (std.math.isNan(n)) return error.Runtime,
            else => {},
        }
        if (t.arrayIndex(k)) |i| {
            if (i < t.array.items.len) {
                t.array.items[i] = v;
                // Removing the last element shrinks the array.
                if (v == .nil and i == t.array.items.len - 1) {
                    while (t.array.items.len > 0 and t.array.items[t.array.items.len - 1] == .nil) t.array.items.len -= 1;
                }
                return;
            }
            if (v == .nil) {
                _ = t.hash.orderedRemove(k);
                return;
            }
            try h.charge(@sizeOf(Value));
            t.array.append(h.gpa, v) catch return error.Memory;
            _ = t.hash.orderedRemove(k);
            // Keys n+1, n+2, … waiting in the hash part join the array.
            while (true) {
                const next: Value = .{ .number = @floatFromInt(t.array.items.len + 1) };
                const moved = t.hash.fetchOrderedRemove(next) orelse break;
                t.array.append(h.gpa, moved.value) catch return error.Memory;
            }
            return;
        }
        if (v == .nil) {
            _ = t.hash.orderedRemove(k);
            return;
        }
        const gop = t.hash.getOrPut(h.gpa, k) catch return error.Memory;
        if (!gop.found_existing) try h.charge(2 * @sizeOf(Value) + 8);
        gop.value_ptr.* = v;
    }

    pub fn setStr(h: *Heap, t: *Table, name: []const u8, v: Value) Error!void {
        const s = try h.str(name);
        s.obj.fixed = t.obj.fixed;
        try h.set(t, .{ .string = s }, v);
    }

    fn free(h: *Heap, o: *Obj) void {
        switch (o.kind) {
            .str => {
                const s: *Str = @fieldParentPtr("obj", o);
                h.bytes -|= @sizeOf(Str) + s.bytes.len;
                h.gpa.free(s.bytes);
                h.gpa.destroy(s);
            },
            .table => {
                const t: *Table = @fieldParentPtr("obj", o);
                h.bytes -|= @sizeOf(Table) + t.array.items.len * @sizeOf(Value) + t.hash.count() * (2 * @sizeOf(Value) + 8);
                t.array.deinit(h.gpa);
                t.hash.deinit(h.gpa);
                h.gpa.destroy(t);
            },
            .function => {
                const f: *Function = @fieldParentPtr("obj", o);
                h.bytes -|= @sizeOf(Function);
                h.gpa.destroy(f);
            },
            .env => {
                const e: *Env = @fieldParentPtr("obj", o);
                h.bytes -|= @sizeOf(Env) + e.slots.len * @sizeOf(Value);
                h.gpa.free(e.slots);
                h.gpa.destroy(e);
            },
        }
    }

    pub fn mark(h: *Heap, v: Value) void {
        switch (v) {
            .string => |s| s.obj.marked = true,
            .table => |t| h.gray(&t.obj),
            .function => |f| h.gray(&f.obj),
            else => {},
        }
    }

    pub fn markEnv(h: *Heap, e: *Env) void {
        h.gray(&e.obj);
    }

    fn gray(h: *Heap, o: *Obj) void {
        if (o.marked) return;
        o.marked = true;
        if (o.kind == .str) return;
        h.grays.append(h.gpa, o) catch {
            h.lost = true;
        };
    }

    /// Marks what the gray objects reach, without recursion (a long
    /// linked list of tables must not overflow the stack).
    fn drain(h: *Heap) void {
        while (h.grays.pop()) |o| switch (o.kind) {
            .str => {},
            .table => {
                const t: *Table = @fieldParentPtr("obj", o);
                for (t.array.items) |v| h.mark(v);
                var it = t.hash.iterator();
                while (it.next()) |e| {
                    h.mark(e.key_ptr.*);
                    h.mark(e.value_ptr.*);
                }
            },
            .function => {
                const f: *Function = @fieldParentPtr("obj", o);
                switch (f.kind) {
                    .closure => |c| if (c.env) |e| h.gray(&e.obj),
                    .native => |n| h.mark(n.bound),
                }
            },
            .env => {
                const e: *Env = @fieldParentPtr("obj", o);
                for (e.slots) |v| h.mark(v);
                if (e.parent) |p| h.gray(&p.obj);
            },
        };
    }

    /// Frees what was not marked (callers mark the roots first), and
    /// clears the marks.
    pub fn sweep(h: *Heap) void {
        // Fixed objects are roots too.
        var o = h.objects;
        while (o) |obj| : (o = obj.next) if (obj.fixed) {
            obj.marked = false;
            h.gray(obj);
        };
        h.drain();
        const keep = h.lost;
        h.lost = false;
        h.grays.clearAndFree(h.gpa);
        var link_: *?*Obj = &h.objects;
        while (link_.*) |obj| {
            if (obj.marked or keep) {
                obj.marked = false;
                link_ = &obj.next;
            } else {
                link_.* = obj.next;
                h.free(obj);
            }
        }
        h.live = h.bytes;
    }

    /// Whether enough was made since the last collection to collect.
    pub fn due(h: *const Heap) bool {
        return h.bytes > @max(2 * h.live, 256 * 1024);
    }
};
