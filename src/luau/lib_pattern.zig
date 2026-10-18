//! Lua patterns and the string functions that use them: `find`, `match`,
//! `gmatch`, `gsub`. Classes (%a %d %s %w …, sets, `.`), quantifiers
//! (* + - ?), anchors, captures (with positions), %b and %f, back
//! references. Matching counts against the step budget.
const std = @import("std");
const value = @import("value.zig");
const ops = @import("ops.zig");
const lib = @import("lib.zig");
const Vm = @import("vm.zig").Vm;
const Value = value.Value;
const Error = value.Error;

const max_captures = 32;
const max_depth = 200;
const position: isize = -2;
const unclosed: isize = -1;

const Matcher = struct {
    vm: *Vm,
    src: []const u8,
    pat: []const u8,
    level: usize = 0,
    caps: [max_captures]struct { start: usize, len: isize } = undefined,
    depth: usize = 0,

    fn fail(m: *Matcher, msg: []const u8) Error {
        return m.vm.fail("{s}", .{msg});
    }

    fn classEnd(m: *Matcher, p: usize) Error!usize {
        var i = p + 1;
        if (m.pat[p] == '%') {
            if (i >= m.pat.len) return m.fail("malformed pattern (ends with '%')");
            return i + 1;
        }
        if (m.pat[p] == '[') {
            if (i < m.pat.len and m.pat[i] == '^') i += 1;
            // The first ']' after '[' (or '[^') is part of the set.
            while (true) {
                if (i >= m.pat.len) return m.fail("malformed pattern (missing ']')");
                const c = m.pat[i];
                i += 1;
                if (c == '%') {
                    i += 1;
                } else if (c == ']' and i > p + 2 + @intFromBool(m.pat[p + 1] == '^')) return i;
            }
        }
        return i;
    }

    fn single(m: *Matcher, s: usize, p: usize, ep: usize) bool {
        if (s >= m.src.len) return false;
        const c = m.src[s];
        return switch (m.pat[p]) {
            '.' => true,
            '%' => classMatch(c, m.pat[p + 1]),
            '[' => setMatch(c, m.pat[p .. ep - 1]),
            else => m.pat[p] == c,
        };
    }

    fn match(m: *Matcher, s_in: usize, p_in: usize) Error!?usize {
        m.depth += 1;
        defer m.depth -= 1;
        if (m.depth > max_depth) return m.fail("pattern too complex");
        try m.vm.tick();
        var s = s_in;
        var p = p_in;
        while (true) {
            if (p >= m.pat.len) return s;
            switch (m.pat[p]) {
                '(' => {
                    if (p + 1 < m.pat.len and m.pat[p + 1] == ')') return m.capture(s, p + 2, position);
                    return m.capture(s, p + 1, unclosed);
                },
                ')' => {
                    const l = m.open() orelse return m.fail("invalid pattern capture");
                    m.caps[l].len = @intCast(s - m.caps[l].start);
                    if (try m.match(s, p + 1)) |e| return e;
                    m.caps[l].len = unclosed;
                    return null;
                },
                '$' => if (p + 1 == m.pat.len) return if (s == m.src.len) s else null,
                '%' => if (p + 1 < m.pat.len) switch (m.pat[p + 1]) {
                    'b' => {
                        s = m.balance(s, p + 2) orelse return null;
                        p += 4;
                        continue;
                    },
                    'f' => {
                        p += 2;
                        if (p >= m.pat.len or m.pat[p] != '[') return m.fail("missing '[' after '%f' in pattern");
                        const ep = try m.classEnd(p);
                        const prev: u8 = if (s == 0) 0 else m.src[s - 1];
                        const cur: u8 = if (s < m.src.len) m.src[s] else 0;
                        if (setMatch(prev, m.pat[p .. ep - 1]) or !setMatch(cur, m.pat[p .. ep - 1])) return null;
                        p = ep;
                        continue;
                    },
                    '0'...'9' => {
                        const l = m.pat[p + 1] - '1';
                        if (l >= m.level or m.caps[l].len < 0) return m.fail("invalid capture index");
                        const cap = m.src[m.caps[l].start..][0..@intCast(m.caps[l].len)];
                        if (!std.mem.startsWith(u8, m.src[s..], cap)) return null;
                        s += cap.len;
                        p += 2;
                        continue;
                    },
                    else => {},
                },
                else => {},
            }
            const ep = try m.classEnd(p);
            const ok = m.single(s, p, ep);
            if (ep < m.pat.len) switch (m.pat[ep]) {
                '?' => {
                    if (ok) if (try m.match(s + 1, ep + 1)) |e| return e;
                    p = ep + 1;
                    continue;
                },
                '+' => return if (ok) m.maxExpand(s + 1, p, ep) else null,
                '*' => return m.maxExpand(s, p, ep),
                '-' => return m.minExpand(s, p, ep),
                else => {},
            };
            if (!ok) return null;
            s += 1;
            p = ep;
        }
    }

    fn maxExpand(m: *Matcher, s: usize, p: usize, ep: usize) Error!?usize {
        var i: usize = 0;
        while (m.single(s + i, p, ep)) i += 1;
        while (true) {
            if (try m.match(s + i, ep + 1)) |e| return e;
            if (i == 0) return null;
            i -= 1;
        }
    }

    fn minExpand(m: *Matcher, s_in: usize, p: usize, ep: usize) Error!?usize {
        var s = s_in;
        while (true) {
            if (try m.match(s, ep + 1)) |e| return e;
            if (!m.single(s, p, ep)) return null;
            s += 1;
        }
    }

    fn capture(m: *Matcher, s: usize, p: usize, what: isize) Error!?usize {
        if (m.level >= max_captures) return m.fail("too many captures");
        m.caps[m.level] = .{ .start = s, .len = what };
        m.level += 1;
        if (try m.match(s, p)) |e| return e;
        m.level -= 1;
        return null;
    }

    fn open(m: *Matcher) ?usize {
        var l = m.level;
        while (l > 0) {
            l -= 1;
            if (m.caps[l].len == unclosed) return l;
        }
        return null;
    }

    fn balance(m: *Matcher, s: usize, p: usize) ?usize {
        if (p + 1 >= m.pat.len) return null;
        if (s >= m.src.len or m.src[s] != m.pat[p]) return null;
        const open_c = m.pat[p];
        const close_c = m.pat[p + 1];
        var depth: usize = 1;
        var i = s + 1;
        while (i < m.src.len) : (i += 1) {
            if (m.src[i] == close_c) {
                depth -= 1;
                if (depth == 0) return i + 1;
            } else if (m.src[i] == open_c) depth += 1;
        }
        return null;
    }

    /// Capture `i` (or the whole match when there are none) as a value.
    fn get(m: *Matcher, i: usize, s: usize, e: usize) Error!Value {
        if (i >= m.level) {
            if (i == 0) return lib.strValue(m.vm, m.src[s..e]);
            return m.fail("invalid capture index");
        }
        const c = m.caps[i];
        if (c.len == position) return .{ .number = @floatFromInt(c.start + 1) };
        if (c.len < 0) return m.fail("unfinished capture");
        return lib.strValue(m.vm, m.src[c.start..][0..@intCast(c.len)]);
    }

    /// Pushes the captures (or the whole match); returns how many.
    fn pushAll(m: *Matcher, s: usize, e: usize) Error!usize {
        const n = @max(m.level, 1);
        for (0..n) |i| try m.vm.push(try m.get(i, s, e));
        return n;
    }
};

fn classMatch(c: u8, cl: u8) bool {
    const res = switch (std.ascii.toLower(cl)) {
        'a' => std.ascii.isAlphabetic(c),
        'c' => std.ascii.isControl(c),
        'd' => std.ascii.isDigit(c),
        'g' => c > 32 and c < 127,
        'l' => std.ascii.isLower(c),
        'p' => std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ',
        's' => std.ascii.isWhitespace(c),
        'u' => std.ascii.isUpper(c),
        'w' => std.ascii.isAlphanumeric(c),
        'x' => std.ascii.isHex(c),
        else => return cl == c,
    };
    return if (std.ascii.isUpper(cl)) !res else res;
}

/// `set` is "[...", without its closing ']'.
fn setMatch(c: u8, set: []const u8) bool {
    var i: usize = 1;
    var negate = false;
    if (i < set.len and set[i] == '^') {
        negate = true;
        i += 1;
    }
    while (i < set.len) : (i += 1) {
        if (set[i] == '%' and i + 1 < set.len) {
            i += 1;
            if (classMatch(c, set[i])) return !negate;
        } else if (i + 2 < set.len and set[i + 1] == '-') {
            if (set[i] <= c and c <= set[i + 2]) return !negate;
            i += 2;
        } else if (set[i] == c) return !negate;
    }
    return negate;
}

fn startAt(vm: *Vm, args: []const Value, i: usize, len: usize, name: []const u8) Error!usize {
    const n = try lib.optNum(vm, args, i, name, 1);
    const start: f64 = if (n < 0) @as(f64, @floatFromInt(len)) + n + 1 else if (n == 0) 1 else n;
    return @intFromFloat(@max(0, @min(@as(f64, @floatFromInt(len + 1)), start) - 1));
}

fn noSpecials(p: []const u8) bool {
    return std.mem.indexOfAny(u8, p, "^$*+?.([%-") == null;
}

fn findOrMatch(vm: *Vm, args: []const Value, is_find: bool) Error![]const Value {
    const name = if (is_find) "find" else "match";
    const s = try lib.strArg(vm, args, 0, name);
    const pat = try lib.strArg(vm, args, 1, name);
    const init = try startAt(vm, args, 2, s.len, name);
    if (init > s.len) return vm.ret(&.{.nil});
    if (is_find and (lib.arg(args, 3).truthy() or noSpecials(pat))) {
        const at = std.mem.indexOfPos(u8, s, init, pat) orelse return vm.ret(&.{.nil});
        return vm.ret(&.{ .{ .number = @floatFromInt(at + 1) }, .{ .number = @floatFromInt(at + pat.len) } });
    }
    const anchor = pat.len > 0 and pat[0] == '^';
    var m: Matcher = .{ .vm = vm, .src = s, .pat = pat };
    var at = init;
    while (true) : (at += 1) {
        m.level = 0;
        if (try m.match(at, @intFromBool(anchor))) |e| {
            const base = vm.top;
            if (is_find) {
                try vm.push(.{ .number = @floatFromInt(at + 1) });
                try vm.push(.{ .number = @floatFromInt(e) });
                if (m.level > 0) _ = try m.pushAll(at, e);
            } else _ = try m.pushAll(at, e);
            return vm.stack[base..vm.top];
        }
        if (anchor or at >= s.len) return vm.ret(&.{.nil});
    }
}

pub fn find(vm: *Vm, args: []const Value) Error![]const Value {
    return findOrMatch(vm, args, true);
}

pub fn match(vm: *Vm, args: []const Value) Error![]const Value {
    return findOrMatch(vm, args, false);
}

/// `gmatch`'s iterator: its state (string, pattern, where) is bound.
fn gmatchNext(vm: *Vm, _: []const Value) Error![]const Value {
    const st = vm.bound.table;
    const s = st.array.items[0].string.bytes;
    const pat = st.array.items[1].string.bytes;
    var at: usize = @intFromFloat(st.array.items[2].number);
    var m: Matcher = .{ .vm = vm, .src = s, .pat = pat };
    while (at <= s.len) : (at += 1) {
        m.level = 0;
        if (try m.match(at, 0)) |e| {
            // An empty match moves on one.
            st.array.items[2] = .{ .number = @floatFromInt(if (e == at) e + 1 else e) };
            const base = vm.top;
            _ = try m.pushAll(at, e);
            return vm.stack[base..vm.top];
        }
    }
    st.array.items[2] = .{ .number = @floatFromInt(s.len + 1) };
    return vm.ret(&.{.nil});
}

pub fn gmatch(vm: *Vm, args: []const Value) Error![]const Value {
    const s = try lib.strArg(vm, args, 0, "gmatch");
    const pat = try lib.strArg(vm, args, 1, "gmatch");
    const st = try vm.heap.table();
    try vm.heap.set(st, .{ .number = 1 }, try lib.strValue(vm, s));
    try vm.heap.set(st, .{ .number = 2 }, try lib.strValue(vm, pat));
    try vm.heap.set(st, .{ .number = 3 }, .{ .number = 0 });
    const f = try vm.heap.function(.{ .kind = .{ .native = .{ .f = lib.wrap(gmatchNext), .name = "gmatch", .bound = .{ .table = st } } } });
    return vm.ret(&.{.{ .function = f }});
}

pub fn gsub(vm: *Vm, args: []const Value) Error![]const Value {
    const s = try lib.strArg(vm, args, 0, "gsub");
    const pat = try lib.strArg(vm, args, 1, "gsub");
    const repl = lib.arg(args, 2);
    if (repl != .string and repl != .number and repl != .table and repl != .function)
        return vm.fail("bad argument #3 to 'gsub' (string/function/table expected)", .{});
    const max_n: f64 = try lib.optNum(vm, args, 3, "gsub", std.math.inf(f64));
    const anchor = pat.len > 0 and pat[0] == '^';
    var m: Matcher = .{ .vm = vm, .src = s, .pat = pat };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.gpa);
    var at: usize = 0;
    var count: f64 = 0;
    while (count < max_n) {
        m.level = 0;
        if (try m.match(at, @intFromBool(anchor))) |e| {
            count += 1;
            try replace(vm, &m, &out, repl, at, e);
            if (e > at) {
                at = e;
            } else {
                if (at < s.len) out.append(vm.gpa, s[at]) catch return error.Memory;
                at += 1;
            }
        } else {
            if (at < s.len) out.append(vm.gpa, s[at]) catch return error.Memory;
            at += 1;
        }
        if (at > s.len or anchor) break;
        if (out.items.len > vm.heap.limit) return error.Memory;
    }
    if (at < s.len) out.appendSlice(vm.gpa, s[at..]) catch return error.Memory;
    return vm.ret(&.{ try lib.strValue(vm, out.items), .{ .number = count } });
}

fn replace(vm: *Vm, m: *Matcher, out: *std.ArrayList(u8), repl: Value, s: usize, e: usize) Error!void {
    const whole = m.src[s..e];
    var buf: [64]u8 = undefined;
    switch (repl) {
        .string, .number => {
            const r = ops.toText(&buf, repl);
            var i: usize = 0;
            while (i < r.len) : (i += 1) {
                if (r[i] != '%' or i + 1 >= r.len) {
                    out.append(vm.gpa, r[i]) catch return error.Memory;
                    continue;
                }
                i += 1;
                if (r[i] == '0') {
                    out.appendSlice(vm.gpa, whole) catch return error.Memory;
                } else if (std.ascii.isDigit(r[i])) {
                    const v = try m.get(r[i] - '1', s, e);
                    out.appendSlice(vm.gpa, ops.toText(&buf, v)) catch return error.Memory;
                } else if (r[i] == '%') {
                    out.append(vm.gpa, '%') catch return error.Memory;
                } else return vm.fail("invalid use of '%' in replacement string", .{});
            }
        },
        .table, .function => {
            const first = try m.get(0, s, e);
            const v = if (repl == .table) repl.table.get(first) else blk: {
                const base = vm.top;
                const n = try m.pushAll(s, e);
                const r = try vm.call(repl, base);
                _ = n;
                const v = if (r > 0) vm.stack[base] else .nil;
                vm.top = base;
                break :blk v;
            };
            if (!v.truthy()) {
                out.appendSlice(vm.gpa, whole) catch return error.Memory;
            } else if (v == .string or v == .number) {
                out.appendSlice(vm.gpa, ops.toText(&buf, v)) catch return error.Memory;
            } else return vm.fail("invalid replacement value (a {s})", .{v.typeName()});
        },
        else => unreachable,
    }
}
