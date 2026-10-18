//! The libraries a visual may use, as in Harness's sandbox: the base
//! functions (no output, loading or environments), `math`, `table`, `utf8`,
//! and `string` (lib_string.zig). `math.random` is seeded, so a visual
//! renders the same each time.
const std = @import("std");
const value = @import("value.zig");
const ops = @import("ops.zig");
const vm_mod = @import("vm.zig");
const lib_string = @import("lib_string.zig");
const Vm = vm_mod.Vm;
const Value = value.Value;
const Error = value.Error;

pub const Native = fn (*Vm, []const Value) Error![]const Value;

pub fn wrap(comptime f: Native) value.NativeFn {
    return struct {
        fn call(p: *anyopaque, args: []const Value) Error![]const Value {
            return f(@ptrCast(@alignCast(p)), args);
        }
    }.call;
}

pub fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else .nil;
}

pub fn num(vm: *Vm, args: []const Value, i: usize, name: []const u8) Error!f64 {
    const v = arg(args, i);
    return ops.toNumber(v) orelse vm.fail("bad argument #{d} to '{s}' (number expected, got {s})", .{ i + 1, name, v.typeName() });
}

pub fn optNum(vm: *Vm, args: []const Value, i: usize, name: []const u8, default: f64) Error!f64 {
    return if (arg(args, i) == .nil) default else num(vm, args, i, name);
}

pub fn tableArg(vm: *Vm, args: []const Value, i: usize, name: []const u8) Error!*value.Table {
    const v = arg(args, i);
    if (v != .table) return vm.fail("bad argument #{d} to '{s}' (table expected, got {s})", .{ i + 1, name, v.typeName() });
    return v.table;
}

/// A string argument; numbers become their text.
pub fn strArg(vm: *Vm, args: []const Value, i: usize, name: []const u8) Error![]const u8 {
    const v = arg(args, i);
    return switch (v) {
        .string => |s| s.bytes,
        .number => |n| blk: {
            var buf: [64]u8 = undefined;
            break :blk (try vm.heap.str(ops.formatNumber(&buf, n))).bytes;
        },
        else => vm.fail("bad argument #{d} to '{s}' (string expected, got {s})", .{ i + 1, name, v.typeName() }),
    };
}

pub fn strValue(vm: *Vm, bytes: []const u8) Error!Value {
    return .{ .string = try vm.heap.str(bytes) };
}

const Entry = struct { []const u8, Native };

/// A library table of `entries`, fixed (never collected), as global `name`.
pub fn install(vm: *Vm, name: ?[]const u8, comptime entries: []const Entry) Error!*value.Table {
    const t = try vm.heap.table();
    t.obj.fixed = true;
    inline for (entries) |e| {
        const fun = try vm.heap.native(e[0], wrap(e[1]));
        fun.obj.fixed = true;
        try vm.heap.setStr(t, e[0], .{ .function = fun });
    }
    if (name) |n| try vm.heap.setStr(vm.globals, n, .{ .table = t });
    return t;
}

/// Puts every library in `vm`'s globals.
pub fn open(vm: *Vm) Error!void {
    const globals = try install(vm, null, &base_fns);
    var it = globals.hash.iterator();
    while (it.next()) |e| try vm.heap.set(vm.globals, e.key_ptr.*, e.value_ptr.*);
    const maths = try install(vm, "math", &math_fns);
    try vm.heap.setStr(maths, "pi", .{ .number = std.math.pi });
    try vm.heap.setStr(maths, "huge", .{ .number = std.math.inf(f64) });
    const tables = try install(vm, "table", &table_fns);
    try vm.heap.setStr(vm.globals, "unpack", tables.getStr("unpack"));
    _ = try install(vm, "utf8", &utf8_fns);
    vm.strings = try install(vm, "string", &lib_string.fns);
    try openHidden(vm);
}

const base_fns = [_]Entry{
    .{ "assert", assert },     .{ "error", @"error" },     .{ "pcall", pcall },
    .{ "type", @"type" },      .{ "typeof", @"type" },     .{ "tostring", tostring },
    .{ "tonumber", tonumber }, .{ "ipairs", ipairs },      .{ "pairs", pairs },
    .{ "next", next },         .{ "select", select },      .{ "rawget", rawget },
    .{ "rawset", rawset },     .{ "rawequal", rawequal },  .{ "rawlen", rawlen },
    .{ "setmetatable", setmetatable }, .{ "getmetatable", getmetatable },
};

fn assert(vm: *Vm, args: []const Value) Error![]const Value {
    if (arg(args, 0).truthy()) return args;
    if (args.len > 1) {
        vm.err_value = args[1];
        return error.Runtime;
    }
    return vm.fail("assertion failed!", .{});
}

fn @"error"(vm: *Vm, args: []const Value) Error![]const Value {
    const v = arg(args, 0);
    const level = try optNum(vm, args, 1, "error", 1);
    if (v == .string and level > 0) return vm.fail("{s}", .{v.string.bytes});
    vm.err_value = v;
    return error.Runtime;
}

fn pcall(vm: *Vm, args: []const Value) Error![]const Value {
    const base = vm.top;
    try vm.push(.{ .boolean = true });
    for (args[@min(1, args.len)..]) |a| try vm.push(a);
    const n = vm.call(arg(args, 0), base + 1) catch |e| {
        if (e != error.Runtime) return e;
        vm.top = base;
        return vm.ret(&.{ .{ .boolean = false }, vm.err_value });
    };
    return vm.stack[base .. base + 1 + n];
}

fn @"type"(vm: *Vm, args: []const Value) Error![]const Value {
    return vm.ret(&.{try strValue(vm, arg(args, 0).typeName())});
}

fn tostring(vm: *Vm, args: []const Value) Error![]const Value {
    const v = arg(args, 0);
    if (v == .string) return vm.ret(&.{v});
    var buf: [64]u8 = undefined;
    return vm.ret(&.{try strValue(vm, ops.toText(&buf, v))});
}

fn tonumber(vm: *Vm, args: []const Value) Error![]const Value {
    const v = arg(args, 0);
    if (arg(args, 1) != .nil) {
        const b = try num(vm, args, 1, "tonumber");
        if (v != .string) return vm.ret(&.{.nil});
        const n = std.fmt.parseInt(i64, std.mem.trim(u8, v.string.bytes, " "), @intFromFloat(b)) catch return vm.ret(&.{.nil});
        return vm.ret(&.{.{ .number = @floatFromInt(n) }});
    }
    return vm.ret(&.{if (ops.toNumber(v)) |n| .{ .number = n } else .nil});
}

fn ipairsNext(vm: *Vm, args: []const Value) Error![]const Value {
    const t = try tableArg(vm, args, 0, "ipairs");
    const i = try num(vm, args, 1, "ipairs") + 1;
    const v = t.get(.{ .number = i });
    if (v == .nil) return vm.ret(&.{.nil});
    return vm.ret(&.{ .{ .number = i }, v });
}

fn ipairs(vm: *Vm, args: []const Value) Error![]const Value {
    _ = try tableArg(vm, args, 0, "ipairs");
    const f = vm.globals.getStr("\x00ipairs");
    return vm.ret(&.{ f, args[0], .{ .number = 0 } });
}

fn pairs(vm: *Vm, args: []const Value) Error![]const Value {
    _ = try tableArg(vm, args, 0, "pairs");
    return vm.ret(&.{ vm.globals.getStr("next"), args[0], .nil });
}

fn next(vm: *Vm, args: []const Value) Error![]const Value {
    const t = try tableArg(vm, args, 0, "next");
    const kv = try vm_mod.next(vm, t, arg(args, 1)) orelse return vm.ret(&.{.nil});
    return vm.ret(&kv);
}

fn select(vm: *Vm, args: []const Value) Error![]const Value {
    const rest = args[@min(1, args.len)..];
    if (arg(args, 0) == .string and std.mem.eql(u8, args[0].string.bytes, "#")) return vm.ret(&.{.{ .number = @floatFromInt(rest.len) }});
    const n = try num(vm, args, 0, "select");
    const len: f64 = @floatFromInt(rest.len);
    const from = if (n < 0) len + n else n - 1;
    if (from < 0) return vm.fail("bad argument #1 to 'select' (index out of range)", .{});
    return rest[@min(rest.len, @as(usize, @intFromFloat(from)))..];
}

fn rawget(vm: *Vm, args: []const Value) Error![]const Value {
    return vm.ret(&.{(try tableArg(vm, args, 0, "rawget")).get(arg(args, 1))});
}

fn rawset(vm: *Vm, args: []const Value) Error![]const Value {
    try vm.setIndex(.{ .table = try tableArg(vm, args, 0, "rawset") }, arg(args, 1), arg(args, 2));
    return vm.ret(&.{args[0]});
}

fn rawequal(vm: *Vm, args: []const Value) Error![]const Value {
    return vm.ret(&.{.{ .boolean = arg(args, 0).eql(arg(args, 1)) }});
}

fn rawlen(vm: *Vm, args: []const Value) Error![]const Value {
    return switch (arg(args, 0)) {
        .table => |t| vm.ret(&.{.{ .number = @floatFromInt(t.len()) }}),
        .string => |s| vm.ret(&.{.{ .number = @floatFromInt(s.bytes.len) }}),
        else => vm.fail("table or string expected", .{}),
    };
}

fn setmetatable(vm: *Vm, _: []const Value) Error![]const Value {
    return vm.fail("metatables are not supported in visuals", .{});
}

fn getmetatable(vm: *Vm, _: []const Value) Error![]const Value {
    return vm.ret(&.{.nil});
}

const M = struct {
    fn abs(x: f64) f64 {
        return @abs(x);
    }
    fn ceil(x: f64) f64 {
        return @ceil(x);
    }
    fn floor(x: f64) f64 {
        return @floor(x);
    }
    fn sqrt(x: f64) f64 {
        return @sqrt(x);
    }
    fn sin(x: f64) f64 {
        return @sin(x);
    }
    fn cos(x: f64) f64 {
        return @cos(x);
    }
    fn tan(x: f64) f64 {
        return @tan(x);
    }
    fn exp(x: f64) f64 {
        return @exp(x);
    }
    fn log10(x: f64) f64 {
        return @log10(x);
    }
    fn asin(x: f64) f64 {
        return std.math.asin(x);
    }
    fn acos(x: f64) f64 {
        return std.math.acos(x);
    }
};

const math_fns = [_]Entry{
    .{ "abs", m1(M.abs) },  .{ "ceil", m1(M.ceil) },  .{ "floor", m1(M.floor) }, .{ "sqrt", m1(M.sqrt) },
    .{ "sin", m1(M.sin) },  .{ "cos", m1(M.cos) },    .{ "tan", m1(M.tan) },     .{ "exp", m1(M.exp) },
    .{ "log10", m1(M.log10) }, .{ "asin", m1(M.asin) }, .{ "acos", m1(M.acos) },
    .{ "atan", atan },      .{ "log", log },          .{ "pow", pow },          .{ "fmod", fmod },
    .{ "modf", modf },      .{ "min", min },          .{ "max", max },          .{ "round", round },
    .{ "clamp", clamp },    .{ "sign", sign },        .{ "random", random },    .{ "randomseed", randomseed },
};

fn m1(comptime f: fn (f64) f64) Native {
    return struct {
        fn call(vm: *Vm, args: []const Value) Error![]const Value {
            const x = try num(vm, args, 0, "math");
            return vm.ret(&.{.{ .number = f(x) }});
        }
    }.call;
}

fn atan(vm: *Vm, args: []const Value) Error![]const Value {
    const y = try num(vm, args, 0, "atan");
    const x = try optNum(vm, args, 1, "atan", 1);
    return vm.ret(&.{.{ .number = std.math.atan2(y, x) }});
}

fn log(vm: *Vm, args: []const Value) Error![]const Value {
    const x = try num(vm, args, 0, "log");
    if (arg(args, 1) == .nil) return vm.ret(&.{.{ .number = @log(x) }});
    return vm.ret(&.{.{ .number = @log(x) / @log(try num(vm, args, 1, "log")) }});
}

fn pow(vm: *Vm, args: []const Value) Error![]const Value {
    return vm.ret(&.{.{ .number = std.math.pow(f64, try num(vm, args, 0, "pow"), try num(vm, args, 1, "pow")) }});
}

fn fmod(vm: *Vm, args: []const Value) Error![]const Value {
    return vm.ret(&.{.{ .number = @rem(try num(vm, args, 0, "fmod"), try num(vm, args, 1, "fmod")) }});
}

fn modf(vm: *Vm, args: []const Value) Error![]const Value {
    const x = try num(vm, args, 0, "modf");
    const i = @trunc(x);
    return vm.ret(&.{ .{ .number = i }, .{ .number = if (std.math.isInf(x)) 0 else x - i } });
}

fn min(vm: *Vm, args: []const Value) Error![]const Value {
    var m = try num(vm, args, 0, "min");
    for (1..args.len) |i| m = @min(m, try num(vm, args, i, "min"));
    return vm.ret(&.{.{ .number = m }});
}

fn max(vm: *Vm, args: []const Value) Error![]const Value {
    var m = try num(vm, args, 0, "max");
    for (1..args.len) |i| m = @max(m, try num(vm, args, i, "max"));
    return vm.ret(&.{.{ .number = m }});
}

fn round(vm: *Vm, args: []const Value) Error![]const Value {
    return vm.ret(&.{.{ .number = @round(try num(vm, args, 0, "round")) }});
}

fn clamp(vm: *Vm, args: []const Value) Error![]const Value {
    const x = try num(vm, args, 0, "clamp");
    const lo = try num(vm, args, 1, "clamp");
    const hi = try num(vm, args, 2, "clamp");
    if (lo > hi) return vm.fail("bad argument #3 to 'clamp' (max must be greater than or equal to min)", .{});
    return vm.ret(&.{.{ .number = std.math.clamp(x, lo, hi) }});
}

fn sign(vm: *Vm, args: []const Value) Error![]const Value {
    const x = try num(vm, args, 0, "sign");
    return vm.ret(&.{.{ .number = if (x > 0) 1 else if (x < 0) -1 else 0 }});
}

fn random(vm: *Vm, args: []const Value) Error![]const Value {
    // xorshift64*, from a seed kept in the globals' hidden slot.
    var s: u64 = @bitCast(ops.toNumber(vm.globals.getStr("\x00seed")) orelse 0x2545F491);
    s ^= s >> 12;
    s ^= s << 25;
    s ^= s >> 27;
    try vm.heap.setStr(vm.globals, "\x00seed", .{ .number = @bitCast(s & 0x7FEF_FFFF_FFFF_FFFF) });
    const r = @as(f64, @floatFromInt((s *% 0x2545F4914F6CDD1D) >> 11)) / @as(f64, 1 << 53);
    if (args.len == 0) return vm.ret(&.{.{ .number = r }});
    const lo = if (args.len >= 2) try num(vm, args, 0, "random") else 1;
    const hi = try num(vm, args, if (args.len >= 2) 1 else 0, "random");
    if (lo > hi) return vm.fail("bad argument to 'random' (interval is empty)", .{});
    return vm.ret(&.{.{ .number = lo + @floor(r * (hi - lo + 1)) }});
}

fn randomseed(vm: *Vm, args: []const Value) Error![]const Value {
    const n = try num(vm, args, 0, "randomseed");
    const seed: u64 = @as(u64, @bitCast(@as(i64, @intFromFloat(@trunc(n))))) | 1;
    try vm.heap.setStr(vm.globals, "\x00seed", .{ .number = @bitCast(seed & 0x7FEF_FFFF_FFFF_FFFF) });
    return &.{};
}

const table_fns = [_]Entry{
    .{ "insert", insert }, .{ "remove", remove }, .{ "concat", concat }, .{ "sort", @import("lib_sort.zig").sort },
    .{ "unpack", unpack }, .{ "pack", pack },     .{ "find", find },     .{ "clear", clear },
    .{ "create", create }, .{ "freeze", freeze }, .{ "isfrozen", isfrozen },
};

fn insert(vm: *Vm, args: []const Value) Error![]const Value {
    const t = try tableArg(vm, args, 0, "insert");
    const n = t.len();
    if (args.len <= 2) {
        try vm.heap.set(t, .{ .number = @floatFromInt(n + 1) }, arg(args, 1));
        return &.{};
    }
    const pos: usize = @intFromFloat(try num(vm, args, 1, "insert"));
    if (pos < 1 or pos > n + 1) return vm.fail("bad argument #2 to 'insert' (position out of bounds)", .{});
    var i = n + 1;
    while (i > pos) : (i -= 1) try vm.heap.set(t, .{ .number = @floatFromInt(i) }, t.get(.{ .number = @floatFromInt(i - 1) }));
    try vm.heap.set(t, .{ .number = @floatFromInt(pos) }, args[2]);
    return &.{};
}

fn remove(vm: *Vm, args: []const Value) Error![]const Value {
    const t = try tableArg(vm, args, 0, "remove");
    const n = t.len();
    if (n == 0) return vm.ret(&.{.nil});
    const pos: usize = @intFromFloat(try optNum(vm, args, 1, "remove", @floatFromInt(n)));
    if (pos < 1 or pos > n) return vm.fail("bad argument #2 to 'remove' (position out of bounds)", .{});
    const out = t.array.items[pos - 1];
    for (pos..n) |i| t.array.items[i - 1] = t.array.items[i];
    try vm.heap.set(t, .{ .number = @floatFromInt(n) }, .nil);
    return vm.ret(&.{out});
}

fn concat(vm: *Vm, args: []const Value) Error![]const Value {
    const t = try tableArg(vm, args, 0, "concat");
    const sep = if (arg(args, 1) == .nil) "" else try strArg(vm, args, 1, "concat");
    const from: usize = @intFromFloat(try optNum(vm, args, 2, "concat", 1));
    const to: usize = @intFromFloat(try optNum(vm, args, 3, "concat", @floatFromInt(t.len())));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    var buf: [64]u8 = undefined;
    var i = from;
    while (i <= to) : (i += 1) {
        const v = t.get(.{ .number = @floatFromInt(i) });
        if (v != .string and v != .number) return vm.fail("invalid value (at index {d}) in table for 'concat'", .{i});
        if (out.items.len + 64 > vm.heap.limit) return error.Memory;
        out.appendSlice(vm.gpa, ops.toText(&buf, v)) catch return error.Memory;
        if (i < to) out.appendSlice(vm.gpa, sep) catch return error.Memory;
    }
    return vm.ret(&.{try strValue(vm, out.items)});
}

fn unpack(vm: *Vm, args: []const Value) Error![]const Value {
    const t = try tableArg(vm, args, 0, "unpack");
    const from: usize = @intFromFloat(@max(1, try optNum(vm, args, 1, "unpack", 1)));
    const to: usize = @intFromFloat(@max(0, try optNum(vm, args, 2, "unpack", @floatFromInt(t.len()))));
    const base = vm.top;
    var i = from;
    while (i <= to) : (i += 1) try vm.push(t.get(.{ .number = @floatFromInt(i) }));
    return vm.stack[base..vm.top];
}

fn pack(vm: *Vm, args: []const Value) Error![]const Value {
    const t = try vm.heap.table();
    for (args, 1..) |a, i| try vm.heap.set(t, .{ .number = @floatFromInt(i) }, a);
    try vm.heap.setStr(t, "n", .{ .number = @floatFromInt(args.len) });
    return vm.ret(&.{.{ .table = t }});
}

fn find(vm: *Vm, args: []const Value) Error![]const Value {
    const t = try tableArg(vm, args, 0, "find");
    const from: usize = @intFromFloat(try optNum(vm, args, 2, "find", 1));
    var i = @max(from, 1);
    while (i <= t.len()) : (i += 1) if (t.array.items[i - 1].eql(arg(args, 1))) return vm.ret(&.{.{ .number = @floatFromInt(i) }});
    return vm.ret(&.{.nil});
}

fn clear(vm: *Vm, args: []const Value) Error![]const Value {
    const t = try tableArg(vm, args, 0, "clear");
    t.array.clearRetainingCapacity();
    t.hash.clearRetainingCapacity();
    return &.{};
}

fn create(vm: *Vm, args: []const Value) Error![]const Value {
    const n = try num(vm, args, 0, "create");
    if (n < 0 or n > 1 << 20) return vm.fail("bad argument #1 to 'create' (size out of range)", .{});
    const t = try vm.heap.table();
    var i: f64 = 1;
    while (i <= n) : (i += 1) try vm.heap.set(t, .{ .number = i }, if (arg(args, 1) == .nil) .{ .boolean = false } else args[1]);
    if (arg(args, 1) == .nil) t.array.clearRetainingCapacity();
    return vm.ret(&.{.{ .table = t }});
}

fn freeze(vm: *Vm, args: []const Value) Error![]const Value {
    return vm.ret(&.{.{ .table = try tableArg(vm, args, 0, "freeze") }});
}

fn isfrozen(vm: *Vm, args: []const Value) Error![]const Value {
    _ = try tableArg(vm, args, 0, "isfrozen");
    return vm.ret(&.{.{ .boolean = false }});
}

const utf8_fns = [_]Entry{ .{ "char", utf8char }, .{ "len", utf8len } };

fn utf8char(vm: *Vm, args: []const Value) Error![]const Value {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    for (0..args.len) |i| {
        var tmp: [4]u8 = undefined;
        const cp: u21 = std.math.cast(u21, @as(i64, @intFromFloat(try num(vm, args, i, "char")))) orelse return vm.fail("bad argument to 'char' (value out of range)", .{});
        const n = std.unicode.utf8Encode(cp, &tmp) catch return vm.fail("bad argument to 'char' (value out of range)", .{});
        out.appendSlice(vm.gpa, tmp[0..n]) catch return error.Memory;
    }
    return vm.ret(&.{try strValue(vm, out.items)});
}

fn utf8len(vm: *Vm, args: []const Value) Error![]const Value {
    const s = try strArg(vm, args, 0, "len");
    const n = std.unicode.utf8CountCodepoints(s) catch return vm.ret(&.{.nil});
    return vm.ret(&.{.{ .number = @floatFromInt(n) }});
}

/// The iterator `ipairs` gives, kept where scripts can't name it.
pub fn openHidden(vm: *Vm) Error!void {
    const f = try vm.heap.native("ipairs_next", wrap(ipairsNext));
    f.obj.fixed = true;
    try vm.heap.setStr(vm.globals, "\x00ipairs", .{ .function = f });
}
