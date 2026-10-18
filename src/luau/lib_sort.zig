//! `table.sort`: a stable merge sort whose comparisons may call back into
//! the script (and fail, which stops it).
const std = @import("std");
const value = @import("value.zig");
const ops = @import("ops.zig");
const lib = @import("lib.zig");
const Vm = @import("vm.zig").Vm;
const Value = value.Value;
const Error = value.Error;

const Less = struct {
    vm: *Vm,
    f: Value,

    fn lt(l: Less, a: Value, b: Value) Error!bool {
        if (l.f != .nil) return (try l.vm.call1(l.f, &.{ a, b })).truthy();
        return ops.less(a, b, false) orelse l.vm.fail("attempt to compare {s} < {s}", .{ a.typeName(), b.typeName() });
    }
};

pub fn sort(vm: *Vm, args: []const Value) Error![]const Value {
    const t = try lib.tableArg(vm, args, 0, "sort");
    const f = lib.arg(args, 1);
    if (f != .nil and f != .function) return vm.fail("bad argument #2 to 'sort' (function expected)", .{});
    // Sort a copy: a comparison may change the table itself.
    const n = t.array.items.len;
    if (n < 2) return &.{};
    const items = vm.gpa.dupe(Value, t.array.items) catch return error.Memory;
    defer vm.gpa.free(items);
    const tmp = vm.gpa.alloc(Value, n) catch return error.Memory;
    defer vm.gpa.free(tmp);
    try mergeSort(.{ .vm = vm, .f = f }, items, tmp);
    for (items, 0..) |v, i| try vm.heap.set(t, .{ .number = @floatFromInt(i + 1) }, v);
    return &.{};
}

fn mergeSort(l: Less, items: []Value, tmp: []Value) Error!void {
    if (items.len <= 8) {
        // Insertion sort for short runs.
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            const x = items[i];
            var j = i;
            while (j > 0 and try l.lt(x, items[j - 1])) : (j -= 1) items[j] = items[j - 1];
            items[j] = x;
        }
        return;
    }
    const mid = items.len / 2;
    try mergeSort(l, items[0..mid], tmp[0..mid]);
    try mergeSort(l, items[mid..], tmp[mid..]);
    @memcpy(tmp[0..items.len], items);
    var a: usize = 0;
    var b: usize = mid;
    var o: usize = 0;
    while (a < mid and b < items.len) : (o += 1) {
        if (try l.lt(tmp[b], tmp[a])) {
            items[o] = tmp[b];
            b += 1;
        } else {
            items[o] = tmp[a];
            a += 1;
        }
    }
    while (a < mid) : (a += 1) {
        items[o] = tmp[a];
        o += 1;
    }
    while (b < items.len) : (b += 1) {
        items[o] = tmp[b];
        o += 1;
    }
}
