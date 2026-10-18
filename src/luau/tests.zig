//! The language as scripts use it: each case runs a chunk and compares
//! what it returns, as text, with what Luau gives.
const std = @import("std");
const luau = @import("luau.zig");

fn run(src: []const u8) ![]const u8 {
    const m = try luau.create(std.testing.allocator, .{});
    defer m.destroy();
    const f = m.load("visual", src) catch {
        std.debug.print("load: {s}\n", .{m.message()});
        return error.Load;
    };
    const out = m.callTop(f, &.{}) catch {
        std.debug.print("run: {s}\n", .{m.message()});
        return error.Run;
    };
    var buf: [64]u8 = undefined;
    var text: std.ArrayList(u8) = .empty;
    for (out, 0..) |v, i| {
        if (i > 0) try text.appendSlice(std.testing.allocator, " ");
        try text.appendSlice(std.testing.allocator, luau.ops.toText(&buf, v));
    }
    return text.toOwnedSlice(std.testing.allocator);
}

fn expect(src: []const u8, want: []const u8) !void {
    const got = try run(src);
    defer std.testing.allocator.free(got);
    std.testing.expectEqualStrings(want, got) catch |e| {
        std.debug.print("source:\n{s}\n", .{src});
        return e;
    };
}

/// The error a chunk stops with.
fn expectError(src: []const u8, want: []const u8) !void {
    const m = try luau.create(std.testing.allocator, .{ .steps = 100_000, .memory = 4 * 1024 * 1024 });
    defer m.destroy();
    const f = m.load("visual", src) catch {
        if (std.mem.indexOf(u8, m.message(), want) == null) {
            std.debug.print("load error: {s}\n", .{m.message()});
            return error.WrongError;
        }
        return;
    };
    _ = m.callTop(f, &.{}) catch {
        if (std.mem.indexOf(u8, m.message(), want) == null) {
            std.debug.print("run error: {s}\n", .{m.message()});
            return error.WrongError;
        }
        return;
    };
    return error.NoError;
}

test "arithmetic, strings and precedence" {
    try expect("return 1 + 2 * 3, 2 ^ 3 ^ 2, -2 ^ 2, 7 // 2, -7 % 3, 10 / 4", "7 512 -4 3 2 2.5");
    try expect("return 'a' .. 'b' .. 1 .. 2, #'hello', '10' + 5", "ab12 5 15");
    try expect("return 1 < 2, 'a' < 'b', 1 == 1.0, nil == false, not nil", "true true true false true");
    try expect("return 1 and 2, nil or 'x', false and error('no')", "2 x false");
    try expect("return 0x10, 1_000, 1e3, .5", "16 1000 1000 0.5");
}

test "locals, closures that capture each loop's variable, varargs" {
    try expect(
        \\local fs = {}
        \\for i = 1, 3 do fs[i] = function() return i * 10 end end
        \\local function count(...) return select('#', ...), ... end
        \\return fs[1](), fs[3](), count(4, 5)
    , "10 30 2 4 5");
    try expect(
        \\local n = 0
        \\local function inc(by: number?): number n += by or 1 return n end
        \\inc() inc(5)
        \\local x = 1 local x = x + 1
        \\return n, x
    , "6 2");
    try expect(
        \\local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
        \\return fib(15)
    , "610");
}

test "control flow: if, while, repeat, continue, generic for" {
    try expect(
        \\local s = 0
        \\for i = 10, 1, -2 do if i == 6 then continue end s += i end
        \\local j = 0 while true do j += 1 if j > 4 then break end end
        \\local k = 0 repeat local done = k >= 3 k += 1 until done
        \\return s, j, k
    , "24 5 4");
    try expect(
        \\local t = {10, 20, 30, name = 'x'}
        \\local a, b = 0, ''
        \\for i, v in ipairs(t) do a += i * v end
        \\for k, v in pairs(t) do b ..= tostring(k) end
        \\local c = 0 for _, v in t do if type(v) == 'number' then c += v end end
        \\return a, b, c
    , "140 123name 60");
    try expect("local x = 5 return if x > 3 then 'big' elseif x > 1 then 'mid' else 'small'", "big");
}

test "tables: length, insert, remove, sort, concat" {
    try expect(
        \\local t = {}
        \\for i = 1, 5 do table.insert(t, i * i) end
        \\table.insert(t, 1, 0)
        \\local r = table.remove(t)
        \\table.sort(t, function(a, b) return a > b end)
        \\return #t, r, table.concat(t, ','), t[#t]
    , "5 25 16,9,4,1,0 0");
    try expect(
        \\local t = {3, 1, 2} t[#t + 1] = 0 table.sort(t)
        \\local u = {} u[2] = 'b' u[1] = 'a'
        \\return table.concat(t, ' '), #u, table.find(t, 2), table.unpack({7, 8})
    , "0 1 2 3 2 3 7 8");
}

test "strings: methods, format, patterns, interpolation" {
    try expect("local s = 'Hello' return s:upper(), s:sub(2, 3), s:rep(2, '-'), ('%d items'):format(3)", "HELLO el Hello-Hello 3 items");
    try expect("return string.format('%5.1f|%-4s|%03d|%x|%g|%g|%.2e', 3.14159, 'ab', 7, 255, 0.5, 1e20, 12345.678)", "  3.1|ab  |007|ff|0.5|1e+20|1.23e+04");
    try expect("return string.format('%s %s %q', 1.5, true, 'a\"b')", "1.5 true \"a\\\"b\"");
    try expect("return ('key = value'):match('(%w+)%s*=%s*(%w+)'), ('a,b,,c'):find(',,'), ('hello world'):gsub('o', '0')", "key 4 hell0 w0rld 2");
    try expect("return ('key = value'):match('(%w+)%s*=%s*(%w+)')", "key value");
    try expect(
        \\local words = {}
        \\for w in ('one two  three'):gmatch('%a+') do table.insert(words, w) end
        \\local n = tostring(1234567):reverse():gsub('(%d%d%d)', '%1,'):reverse():gsub('^,', '')
        \\return #words, words[3], n
    , "3 three 1,234,567");
    try expect("local n, unit = 42, 'ms' return `took {n}{unit} ({n * 2})`, `\\{literal}`", "took 42ms (84) {literal}");
    try expect("return #('a,b,c'):split(','), math.max(3, 9, 2), math.floor(-2.5), math.clamp(15, 0, 10), math.round(2.5)", "3 9 -3 10 3");
}

test "errors: pcall, error values, messages with lines" {
    try expect("local ok, e = pcall(function() error('boom') end) return ok, e", "false visual:1: boom");
    try expect("local ok, e = pcall(error, {code = 7}) return ok, e.code", "false 7");
    try expect("return pcall(function(a, b) return a + b end, 2, 3)", "true 5");
    try expectError("local t = nil\nreturn t.x", "visual:2: attempt to index nil with x");
    try expectError("return 1 + {}", "attempt to perform arithmetic (add) on table");
    try expectError("return nope()", "attempt to call a nil value");
    try expectError("local x = = 1", "visual:1:");
    try expectError("return setmetatable({}, {})", "metatables are not supported");
}

test "budgets: steps, memory and depth stop a script, and pcall can't catch them" {
    try expectError("while true do end", "budget");
    try expectError("local ok = pcall(function() while true do end end) return ok", "budget");
    try expectError("local t = {} for i = 1, 1e7 do t[i] = ('x'):rep(100) .. i end", "memory");
    try expectError("local function f() return f() + 1 end return f()", "stack overflow");
    const deep = "return " ++ @as([200]u8, @splat('(')) ++ "1" ++ @as([200]u8, @splat(')'));
    try expectError(deep, "too deeply nested");
}

test "types are read and ignored" {
    try expect(
        \\type Point = { x: number, y: number }
        \\export type List<T> = { T }
        \\local function len(p: Point, scale: number?): number
        \\    return (p.x * (scale or 1)) :: number
        \\end
        \\local f: (number) -> string = function(n) return tostring(n) end
        \\local u: string | nil = nil
        \\return len({x = 3, y = 4}, 2), f(1), u
    , "6 1 nil");
}

test "the garbage collector frees what nothing reaches" {
    const m = try luau.create(std.testing.allocator, .{});
    defer m.destroy();
    const f = try m.load("visual",
        \\local keep = {}
        \\return function()
        \\  for i = 1, 2000 do local t = {i, tostring(i)} end
        \\  keep[#keep + 1] = 'kept'
        \\  return #keep
        \\end
    );
    const render = (try m.callTop(f, &.{}))[0];
    m.collect(&.{render});
    const before = m.heap.bytes;
    for (0..5) |_| {
        _ = try m.callTop(render, &.{});
        m.collect(&.{render});
    }
    // Garbage from each call is gone; only the kept strings grow.
    try std.testing.expect(m.heap.bytes < before + 4096);
    const n = (try m.callTop(render, &.{}))[0];
    try std.testing.expectEqual(@as(f64, 6), n.number);
}
