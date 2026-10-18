//! What Luau's operators do to values: arithmetic (numbers, and strings
//! that are numbers), comparison, concatenation, length, and how numbers
//! and other values become text.
const std = @import("std");
const value = @import("value.zig");
const ast = @import("ast.zig");
const Value = value.Value;

/// A number from a value: numbers, and strings that read as one.
pub fn toNumber(v: Value) ?f64 {
    return switch (v) {
        .number => |n| n,
        .string => |s| parseNumber(s.bytes),
        else => null,
    };
}

pub fn parseNumber(text: []const u8) ?f64 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return null;
    const neg = t[0] == '-';
    const body = if (neg or t[0] == '+') t[1..] else t;
    if (body.len > 2 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X')) {
        const n = std.fmt.parseInt(u64, body[2..], 16) catch return null;
        const f: f64 = @floatFromInt(n);
        return if (neg) -f else f;
    }
    for (body) |ch| if (!(std.ascii.isDigit(ch) or ch == '.' or ch == 'e' or ch == 'E' or ch == '+' or ch == '-')) return null;
    const f = std.fmt.parseFloat(f64, body) catch return null;
    return if (neg) -f else f;
}

pub fn arith(op: ast.BinOp, a: f64, b: f64) f64 {
    return switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
        .idiv => @floor(a / b),
        .mod => if (std.math.isInf(b) and !std.math.isInf(a))
            (if ((a >= 0) == (b > 0)) a else b)
        else
            a - @floor(a / b) * b,
        .pow => std.math.pow(f64, a, b),
        else => unreachable,
    };
}

pub fn opName(op: ast.BinOp) []const u8 {
    return switch (op) {
        .add => "add",
        .sub => "sub",
        .mul => "mul",
        .div => "div",
        .idiv => "idiv",
        .mod => "mod",
        .pow => "pow",
        .concat => "concat",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        else => "?",
    };
}

/// `a < b` (or `<=`) for numbers or strings; null when they can't compare.
pub fn less(a: Value, b: Value, or_equal: bool) ?bool {
    if (a == .number and b == .number) return if (or_equal) a.number <= b.number else a.number < b.number;
    if (a == .string and b == .string) {
        const o = std.mem.order(u8, a.string.bytes, b.string.bytes);
        return if (or_equal) o != .gt else o == .lt;
    }
    return null;
}

/// How Luau writes a number: integers without a point, others in the
/// shortest form that reads back the same.
pub fn formatNumber(buf: []u8, n: f64) []const u8 {
    if (std.math.isNan(n)) return "nan";
    if (std.math.isInf(n)) return if (n > 0) "inf" else "-inf";
    if (n == @floor(n) and @abs(n) < 1e15) {
        if (n == 0 and std.math.signbit(n)) return "-0";
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(n))}) catch "?";
    }
    if (@abs(n) >= 1e15 or @abs(n) < 1e-4) return std.fmt.bufPrint(buf, "{e}", .{n}) catch "?";
    return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
}

/// What `tostring` gives for strings and numbers and the rest.
pub fn toText(buf: []u8, v: Value) []const u8 {
    return switch (v) {
        .nil => "nil",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| formatNumber(buf, n),
        .string => |s| s.bytes,
        .table => |t| std.fmt.bufPrint(buf, "table: 0x{x:0>8}", .{@intFromPtr(t)}) catch "table",
        .function => |f| std.fmt.bufPrint(buf, "function: 0x{x:0>8}", .{@intFromPtr(f)}) catch "function",
    };
}

test "numbers as Luau writes them" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("3", formatNumber(&buf, 3));
    try std.testing.expectEqualStrings("-12", formatNumber(&buf, -12));
    try std.testing.expectEqualStrings("0.1", formatNumber(&buf, 0.1));
    try std.testing.expectEqualStrings("2.5", formatNumber(&buf, 2.5));
    try std.testing.expectEqual(@as(?f64, 255), parseNumber("0xff"));
    try std.testing.expectEqual(@as(?f64, -1.5), parseNumber(" -1.5 "));
    try std.testing.expectEqual(@as(?f64, null), parseNumber("12px"));
    try std.testing.expectEqual(@as(f64, 2), arith(.mod, -1, 3));
    try std.testing.expectEqual(@as(f64, -2), arith(.idiv, -3, 2));
}
