//! A small Luau, for the visuals agents show (Harness's `show_visual`
//! scripts): Lua 5.1 with Luau's additions, its libraries without anything
//! that reaches outside (files, processes, network, clock, output, loading
//! code), and budgets for steps, memory and depth. Written in Zig, as
//! nanoui allows no C.
const std = @import("std");
pub const value = @import("value.zig");
pub const vm = @import("vm.zig");
pub const lib = @import("lib.zig");
pub const ops = @import("ops.zig");
pub const Vm = vm.Vm;
pub const Value = value.Value;
pub const Error = value.Error;
pub const Options = vm.Options;

/// A machine with the libraries open.
pub fn create(gpa: std.mem.Allocator, options: Options) !*Vm {
    const m = try Vm.create(gpa, options);
    errdefer m.destroy();
    try lib.open(m);
    return m;
}

test {
    _ = @import("tests.zig");
    _ = ops;
}
