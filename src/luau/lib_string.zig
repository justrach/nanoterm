//! The `string` library (also reached as methods, `s:upper()`): lengths,
//! pieces, case, repetition, bytes, Luau's `split`, `format` as C's printf
//! has it, and the pattern functions (lib_pattern.zig).
const std = @import("std");
const value = @import("value.zig");
const ops = @import("ops.zig");
const lib = @import("lib.zig");
const pattern = @import("lib_pattern.zig");
const Vm = @import("vm.zig").Vm;
const Value = value.Value;
const Error = value.Error;

pub const fns = [_]struct { []const u8, lib.Native }{
    .{ "len", len },         .{ "sub", sub },         .{ "upper", upper },     .{ "lower", lower },
    .{ "rep", rep },         .{ "reverse", reverse }, .{ "byte", byte },       .{ "char", char },
    .{ "format", format },   .{ "split", split },     .{ "find", pattern.find }, .{ "match", pattern.match },
    .{ "gmatch", pattern.gmatch }, .{ "gsub", pattern.gsub },
};

fn len(vm: *Vm, args: []const Value) Error![]const Value {
    return vm.ret(&.{.{ .number = @floatFromInt((try lib.strArg(vm, args, 0, "len")).len) }});
}

/// Lua's string positions (1-based, negative from the end) to a range.
fn range(n: usize, i_in: f64, j_in: f64) struct { usize, usize } {
    const len_f: f64 = @floatFromInt(n);
    var i = if (i_in < 0) @max(len_f + i_in + 1, 1) else if (i_in == 0) 1 else i_in;
    var j = if (j_in < 0) len_f + j_in + 1 else @min(j_in, len_f);
    i = @floor(i);
    j = @floor(j);
    if (i > j) return .{ 0, 0 };
    return .{ @intFromFloat(i - 1), @intFromFloat(j) };
}

fn sub(vm: *Vm, args: []const Value) Error![]const Value {
    const s = try lib.strArg(vm, args, 0, "sub");
    const r = range(s.len, try lib.optNum(vm, args, 1, "sub", 1), try lib.optNum(vm, args, 2, "sub", -1));
    return vm.ret(&.{try lib.strValue(vm, s[r[0]..r[1]])});
}

fn mapped(vm: *Vm, args: []const Value, comptime f: fn (u8) u8, name: []const u8) Error![]const Value {
    const s = try lib.strArg(vm, args, 0, name);
    const out = vm.gpa.alloc(u8, s.len) catch return error.Memory;
    for (s, out) |c, *o| o.* = f(c);
    return vm.ret(&.{.{ .string = try vm.heap.strOwned(out) }});
}

fn upper(vm: *Vm, args: []const Value) Error![]const Value {
    return mapped(vm, args, std.ascii.toUpper, "upper");
}

fn lower(vm: *Vm, args: []const Value) Error![]const Value {
    return mapped(vm, args, std.ascii.toLower, "lower");
}

fn rep(vm: *Vm, args: []const Value) Error![]const Value {
    const s = try lib.strArg(vm, args, 0, "rep");
    const n_f = @max(0, @floor(try lib.num(vm, args, 1, "rep")));
    const sep = if (lib.arg(args, 2) == .nil) "" else try lib.strArg(vm, args, 2, "rep");
    const total = n_f * @as(f64, @floatFromInt(s.len + sep.len));
    if (total > @as(f64, @floatFromInt(vm.heap.limit))) return error.Memory;
    const n: usize = @intFromFloat(n_f);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(vm.gpa);
    for (0..n) |i| {
        out.appendSlice(vm.gpa, s) catch return error.Memory;
        if (i + 1 < n) out.appendSlice(vm.gpa, sep) catch return error.Memory;
    }
    return vm.ret(&.{.{ .string = try vm.heap.strOwned(out.toOwnedSlice(vm.gpa) catch return error.Memory) }});
}

fn reverse(vm: *Vm, args: []const Value) Error![]const Value {
    const s = try lib.strArg(vm, args, 0, "reverse");
    const out = vm.gpa.dupe(u8, s) catch return error.Memory;
    std.mem.reverse(u8, out);
    return vm.ret(&.{.{ .string = try vm.heap.strOwned(out) }});
}

fn byte(vm: *Vm, args: []const Value) Error![]const Value {
    const s = try lib.strArg(vm, args, 0, "byte");
    const i = try lib.optNum(vm, args, 1, "byte", 1);
    const r = range(s.len, i, try lib.optNum(vm, args, 2, "byte", i));
    const base = vm.top;
    for (s[r[0]..r[1]]) |c| try vm.push(.{ .number = @floatFromInt(c) });
    return vm.stack[base..vm.top];
}

fn char(vm: *Vm, args: []const Value) Error![]const Value {
    const out = vm.gpa.alloc(u8, args.len) catch return error.Memory;
    for (out, 0..) |*o, i| {
        const c = try lib.num(vm, args, i, "char");
        if (c < 0 or c > 255) {
            vm.gpa.free(out);
            return vm.fail("bad argument #{d} to 'char' (value out of range)", .{i + 1});
        }
        o.* = @intFromFloat(c);
    }
    return vm.ret(&.{.{ .string = try vm.heap.strOwned(out) }});
}

fn split(vm: *Vm, args: []const Value) Error![]const Value {
    const s = try lib.strArg(vm, args, 0, "split");
    const sep = if (lib.arg(args, 1) == .nil) "," else try lib.strArg(vm, args, 1, "split");
    const t = try vm.heap.table();
    var n: f64 = 1;
    if (sep.len == 0) {
        for (0..s.len) |i| {
            try vm.heap.set(t, .{ .number = n }, try lib.strValue(vm, s[i .. i + 1]));
            n += 1;
        }
    } else {
        var it = std.mem.splitSequence(u8, s, sep);
        while (it.next()) |piece| {
            try vm.heap.set(t, .{ .number = n }, try lib.strValue(vm, piece));
            n += 1;
        }
    }
    return vm.ret(&.{.{ .table = t }});
}

const Spec = struct {
    left: bool = false,
    zero: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    width: usize = 0,
    precision: ?usize = null,
};

fn format(vm: *Vm, args: []const Value) Error![]const Value {
    const f = try lib.strArg(vm, args, 0, "format");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    var next_arg: usize = 1;
    var i: usize = 0;
    while (i < f.len) : (i += 1) {
        if (f[i] != '%') {
            out.append(vm.gpa, f[i]) catch return error.Memory;
            continue;
        }
        i += 1;
        if (i >= f.len) return vm.fail("invalid conversion '%' to 'format'", .{});
        if (f[i] == '%') {
            out.append(vm.gpa, '%') catch return error.Memory;
            continue;
        }
        var spec: Spec = .{};
        while (i < f.len) : (i += 1) switch (f[i]) {
            '-' => spec.left = true,
            '0' => spec.zero = true,
            '+' => spec.plus = true,
            ' ' => spec.space = true,
            '#' => spec.alt = true,
            else => break,
        };
        while (i < f.len and std.ascii.isDigit(f[i])) : (i += 1) spec.width = @min(99, spec.width * 10 + (f[i] - '0'));
        if (i < f.len and f[i] == '.') {
            i += 1;
            var p: usize = 0;
            while (i < f.len and std.ascii.isDigit(f[i])) : (i += 1) p = @min(99, p * 10 + (f[i] - '0'));
            spec.precision = p;
        }
        if (i >= f.len) return vm.fail("invalid conversion to 'format'", .{});
        const conv = f[i];
        const n = next_arg;
        next_arg += 1;
        var buf: [512]u8 = undefined;
        const body: []const u8 = switch (conv) {
            'd', 'i', 'u' => try integer(&buf, @trunc(try lib.num(vm, args, n, "format")), 10, false, spec),
            'x', 'X', 'o' => try integer(&buf, @trunc(try lib.num(vm, args, n, "format")), if (conv == 'o') 8 else 16, conv == 'X', spec),
            'c' => blk: {
                buf[0] = @intFromFloat(std.math.clamp(try lib.num(vm, args, n, "format"), 0, 255));
                break :blk buf[0..1];
            },
            'f', 'F', 'e', 'E', 'g', 'G' => try float(&buf, try lib.num(vm, args, n, "format"), conv, spec),
            's' => blk: {
                var tb: [64]u8 = undefined;
                const v = lib.arg(args, n);
                if (n >= args.len) return vm.fail("bad argument #{d} to 'format' (no value)", .{n + 1});
                const t = ops.toText(&tb, v);
                const cut = if (spec.precision) |p| t[0..@min(p, t.len)] else t;
                if (v == .string) {
                    try pad(vm, &out, cut, spec, false);
                    continue;
                }
                @memcpy(buf[0..cut.len], cut);
                break :blk buf[0..cut.len];
            },
            'q' => {
                const s = try lib.strArg(vm, args, n, "format");
                out.append(vm.gpa, '"') catch return error.Memory;
                for (s) |c| switch (c) {
                    '"', '\\' => out.appendSlice(vm.gpa, &.{ '\\', c }) catch return error.Memory,
                    '\n' => out.appendSlice(vm.gpa, "\\n") catch return error.Memory,
                    '\r' => out.appendSlice(vm.gpa, "\\r") catch return error.Memory,
                    0 => out.appendSlice(vm.gpa, "\\0") catch return error.Memory,
                    else => out.append(vm.gpa, c) catch return error.Memory,
                };
                out.append(vm.gpa, '"') catch return error.Memory;
                continue;
            },
            else => return vm.fail("invalid conversion '%{c}' to 'format'", .{conv}),
        };
        try pad(vm, &out, body, spec, conv != 's' and conv != 'c');
        if (out.items.len > vm.heap.limit) return error.Memory;
    }
    return vm.ret(&.{try lib.strValue(vm, out.items)});
}

/// Writes `body` in a field of the spec's width.
fn pad(vm: *Vm, out: *std.ArrayList(u8), body: []const u8, spec: Spec, numeric: bool) Error!void {
    const fill = spec.width -| body.len;
    if (spec.left) {
        out.appendSlice(vm.gpa, body) catch return error.Memory;
        out.appendNTimes(vm.gpa, ' ', fill) catch return error.Memory;
        return;
    }
    if (spec.zero and numeric and fill > 0) {
        // Zeros go after the sign.
        const signed = body.len > 0 and (body[0] == '-' or body[0] == '+' or body[0] == ' ');
        if (signed) out.append(vm.gpa, body[0]) catch return error.Memory;
        out.appendNTimes(vm.gpa, '0', fill) catch return error.Memory;
        out.appendSlice(vm.gpa, body[@intFromBool(signed)..]) catch return error.Memory;
        return;
    }
    out.appendNTimes(vm.gpa, ' ', fill) catch return error.Memory;
    out.appendSlice(vm.gpa, body) catch return error.Memory;
}

fn sign(spec: Spec, negative: bool) []const u8 {
    return if (negative) "-" else if (spec.plus) "+" else if (spec.space) " " else "";
}

fn integer(buf: []u8, n: f64, base: u8, up: bool, spec: Spec) Error![]const u8 {
    const v: i64 = if (std.math.isFinite(n)) @intFromFloat(std.math.clamp(n, -9.2e18, 9.2e18)) else 0;
    const mag: u64 = @abs(v);
    var digits: [64]u8 = undefined;
    const d = digits[0..std.fmt.printInt(&digits, mag, base, if (up) .upper else .lower, .{})];
    const min = spec.precision orelse 1;
    const zeros = min -| d.len;
    const prefix: []const u8 = if (spec.alt and base == 16 and mag != 0) (if (up) "0X" else "0x") else "";
    var o: usize = 0;
    for ([_][]const u8{ sign(spec, v < 0), prefix }) |part| {
        @memcpy(buf[o..][0..part.len], part);
        o += part.len;
    }
    @memset(buf[o..][0..zeros], '0');
    o += zeros;
    @memcpy(buf[o..][0..d.len], d);
    return buf[0 .. o + d.len];
}

fn float(buf: []u8, n: f64, conv: u8, spec: Spec) Error![]const u8 {
    const up = std.ascii.isUpper(conv);
    if (std.math.isNan(n)) return if (up) "NAN" else "nan";
    if (std.math.isInf(n)) return std.fmt.bufPrint(buf, "{s}{s}", .{ sign(spec, n < 0), if (up) "INF" else "inf" }) catch unreachable;
    const p = spec.precision orelse 6;
    const mag = @abs(n);
    var tmp: [400]u8 = undefined;
    var body: []const u8 = undefined;
    switch (std.ascii.toLower(conv)) {
        'f' => body = std.fmt.float.render(&tmp, mag, .{ .mode = .decimal, .precision = p }) catch "?",
        'e' => body = scientific(&tmp, mag, p, up),
        else => {
            // %g: %e or %f by the exponent, then without trailing zeros.
            const P = if (p == 0) 1 else p;
            const x: i64 = if (mag == 0) 0 else @intFromFloat(@floor(@log10(mag)));
            // Rounding can carry into the next power of ten.
            var e_buf: [400]u8 = undefined;
            const e_text = scientific(&e_buf, mag, P - 1, up);
            const ex = std.fmt.parseInt(i64, e_text[std.mem.indexOfAny(u8, e_text, "eE").? + 1 ..], 10) catch x;
            if (@as(i64, @intCast(P)) > ex and ex >= -4) {
                body = std.fmt.float.render(&tmp, mag, .{ .mode = .decimal, .precision = @intCast(@as(i64, @intCast(P)) - 1 - ex) }) catch "?";
                if (!spec.alt) body = trimZeros(body);
            } else {
                const at = std.mem.indexOfAny(u8, e_text, "eE").?;
                const mant = if (spec.alt) e_text[0..at] else trimZeros(e_text[0..at]);
                body = std.fmt.bufPrint(&tmp, "{s}{s}", .{ mant, e_text[at..] }) catch "?";
            }
        },
    }
    return std.fmt.bufPrint(buf, "{s}{s}", .{ sign(spec, n < 0 or (n == 0 and std.math.signbit(n))), body }) catch "?";
}

fn trimZeros(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '.') == null) return s;
    var t = std.mem.trimEnd(u8, s, "0");
    if (t.len > 0 and t[t.len - 1] == '.') t = t[0 .. t.len - 1];
    return t;
}

/// C's %e: one digit, the point, `p` digits, and e±dd.
fn scientific(buf: []u8, mag: f64, p: usize, up: bool) []const u8 {
    var tmp: [400]u8 = undefined;
    const r = std.fmt.float.render(&tmp, mag, .{ .mode = .scientific, .precision = p }) catch return "?";
    const at = std.mem.indexOfScalar(u8, r, 'e') orelse return r;
    const ex = std.fmt.parseInt(i64, r[at + 1 ..], 10) catch 0;
    return std.fmt.bufPrint(buf, "{s}{c}{c}{d:0>2}", .{ r[0..at], @as(u8, if (up) 'E' else 'e'), @as(u8, if (ex < 0) '-' else '+'), @abs(ex) }) catch "?";
}
