//! Visuals, as Harness's `show_visual` has them: a Luau script keeps its
//! state in locals and returns a render function; rendering gives a tree of
//! nodes nanoterm draws natively (rows, columns, text, stats, bar charts,
//! buttons, toggles, sliders, rules). Controls call back into the script
//! and the tree is rendered again; no model is asked, nothing runs outside.
//! The host owns every color, font and spacing: unknown kinds and
//! properties (styles) are errors, as are holes in arrays and NaN.
const std = @import("std");
const luau = @import("luau/luau.zig");
const lib = luau.lib;
const Value = luau.Value;
const Error = luau.Error;

pub const max_title = 200;
pub const max_source = 64 * 1024;
const max_nodes = 512;
const max_depth = 24;
const max_text = 8 * 1024;
const max_series = 256;

const more = @import("visual_more.zig");

/// Harness's kinds, then nanoterm's own (visual_more.zig).
pub const Kind = enum { column, row, text, stat, chart, button, toggle, slider, rule, heading, note, flow, tabs, list, table, code, badge, progress, group };

/// A badge's meaning; the host picks its color.
pub const Tone = enum { neutral, accent, success, warning, danger };

pub const Node = struct {
    kind: Kind,
    /// Text, a stat's value, a control's label, a chart's label.
    text: []const u8 = "",
    /// A stat's label.
    label: []const u8 = "",
    children: []Node = &.{},
    value: f64 = 0,
    min: f64 = 0,
    max: f64 = 1,
    values: []f64 = &.{},
    /// Chart labels; a flow's steps, tabs' options, a list's items, a
    /// table's columns.
    labels: []const []const u8 = &.{},
    rows: []const []const []const u8 = &.{},
    tone: Tone = .neutral,
    ordered: bool = false,
    /// Index of the control's callback in this render.
    handler: ?u32 = null,
};

pub const Input = union(enum) { click, number: f64, boolean: bool };

pub const Expected = enum { click, boolean, number };
pub const Handler = struct { f: Value, expected: Expected, min: f64 = 0, max: f64 = 0 };

fn allowed(kind: Kind) []const []const u8 {
    return switch (kind) {
        .column, .row, .rule => &.{},
        .text => &.{"text"},
        .stat => &.{ "label", "value" },
        .chart => &.{ "label", "values", "labels" },
        .button => &.{ "label", "onClick" },
        .toggle => &.{ "label", "value", "onChange" },
        .slider => &.{ "label", "value", "min", "max", "onChange" },
        else => more.allowed(kind),
    };
}

/// Checks that `t` has only what a `kind` node may have.
fn checkProperties(vm: *luau.Vm, t: *luau.value.Table, kind: Kind) Error!void {
    if (t.array.items.len > 0 and kind != .column and kind != .row and kind != .group) return vm.fail("unsupported visual property (styling is not supported)", .{});
    if (t.array.items.len > max_nodes) return vm.fail("visual array exceeds its size limit", .{});
    var it = t.hash.iterator();
    while (it.next()) |e| {
        const ok = switch (e.key_ptr.*) {
            .string => |s| std.mem.eql(u8, s.bytes, "__kind") or for (allowed(kind)) |a| {
                if (std.mem.eql(u8, a, s.bytes)) break true;
            } else false,
            else => false,
        };
        if (!ok) return vm.fail("unsupported visual property{s}{s} (styling is not supported)", .{ if (e.key_ptr.* == .string) " " else "", if (e.key_ptr.* == .string) e.key_ptr.string.bytes else "" });
    }
}

/// `ui.<kind>{…}`: checks the table and marks what it is.
fn construct(vm: *luau.Vm, args: []const Value) Error![]const Value {
    const kind: Kind = @enumFromInt(@as(u8, @intFromFloat(vm.bound.number)));
    const a = lib.arg(args, 0);
    const t = switch (a) {
        .table => |t| t,
        .string, .number => if (kind == .text or kind == .heading or kind == .note or kind == .code) blk: {
            const t = try vm.heap.table();
            try vm.heap.setStr(t, "text", a);
            break :blk t;
        } else return vm.fail("visual constructors require a property table (or a text string)", .{}),
        else => return vm.fail("visual constructors require a property table (or a text string)", .{}),
    };
    try checkProperties(vm, t, kind);
    try vm.heap.setStr(t, "__kind", .{ .string = try vm.heap.str(@tagName(kind)) });
    return vm.ret(&.{.{ .table = t }});
}

pub const Visual = struct {
    gpa: std.mem.Allocator,
    vm: *luau.Vm,
    renderer: Value = .nil,
    handlers: std.ArrayList(Handler) = .empty,
    /// The latest tree, and where it lives.
    tree: ?Node = null,
    arena: std.heap.ArenaAllocator,
    /// Why the visual stopped, if it did.
    err: ?[]u8 = null,
    source: []u8,

    /// A visual of `source`, rendered once. A script that fails leaves
    /// `err` set rather than failing here.
    pub fn create(gpa: std.mem.Allocator, source: []const u8) !*Visual {
        const v = try gpa.create(Visual);
        errdefer gpa.destroy(v);
        v.* = .{ .gpa = gpa, .vm = undefined, .arena = .init(gpa), .source = try gpa.dupe(u8, source) };
        errdefer gpa.free(v.source);
        try v.start();
        return v;
    }

    pub fn destroy(v: *Visual) void {
        v.vm.destroy();
        v.handlers.deinit(v.gpa);
        v.arena.deinit();
        if (v.err) |e| v.gpa.free(e);
        v.gpa.free(v.source);
        v.gpa.destroy(v);
    }

    /// Starts over from the script: its first state, rendered.
    pub fn reset(v: *Visual) !void {
        v.vm.destroy();
        v.handlers.clearRetainingCapacity();
        v.tree = null;
        _ = v.arena.reset(.retain_capacity);
        if (v.err) |e| v.gpa.free(e);
        v.err = null;
        try v.start();
    }

    fn start(v: *Visual) !void {
        v.vm = try luau.create(v.gpa, .{ .stack = 1 << 13 });
        errdefer v.vm.destroy();
        const ui = try v.vm.heap.table();
        ui.obj.fixed = true;
        for (std.enums.values(Kind)) |k| {
            const fun = try v.vm.heap.function(.{ .kind = .{ .native = .{ .f = lib.wrap(construct), .name = @tagName(k), .bound = .{ .number = @floatFromInt(@intFromEnum(k)) } } } });
            fun.obj.fixed = true;
            try v.vm.heap.setStr(ui, @tagName(k), .{ .function = fun });
        }
        try v.vm.heap.setStr(v.vm.globals, "ui", .{ .table = ui });
        if (v.source.len > max_source) return v.stop("visual source exceeds 64 KiB");
        const chunk = v.vm.load("visual", v.source) catch return v.stop(v.vm.message());
        const out = v.vm.callTop(chunk, &.{}) catch return v.stop(v.vm.message());
        if (out.len == 0 or out[0] != .function) return v.stop("a visual's script must return a render function");
        v.renderer = out[0];
        v.render();
    }

    fn stop(v: *Visual, msg: []const u8) void {
        if (v.err) |e| v.gpa.free(e);
        v.err = v.gpa.dupe(u8, msg) catch null;
        v.tree = null;
        v.handlers.clearRetainingCapacity();
    }

    /// Renders the tree again from the script's state.
    pub fn render(v: *Visual) void {
        v.handlers.clearRetainingCapacity();
        v.tree = null;
        _ = v.arena.reset(.retain_capacity);
        const out = v.vm.callTop(v.renderer, &.{}) catch return v.stop(v.vm.message());
        var p: Parse = .{ .v = v, .a = v.arena.allocator() };
        const root = p.node(if (out.len > 0) out[0] else .nil, 1) catch |e| return v.stop(if (e == error.OutOfMemory) "out of memory" else p.msg);
        v.tree = root;
        // Only the renderer and this render's callbacks are kept.
        var roots: std.ArrayList(Value) = .empty;
        defer roots.deinit(v.gpa);
        roots.append(v.gpa, v.renderer) catch return;
        for (v.handlers.items) |h| roots.append(v.gpa, h.f) catch return;
        v.vm.collect(roots.items);
    }

    /// Gives a control's input to its callback, then renders again.
    pub fn call(v: *Visual, handler: u32, input: Input) void {
        if (v.err != null or handler >= v.handlers.items.len) return;
        const h = v.handlers.items[handler];
        const arg: Value = switch (input) {
            .click => if (h.expected == .click) .nil else return,
            .boolean => |b| if (h.expected == .boolean) .{ .boolean = b } else return,
            .number => |n| if (h.expected == .number and std.math.isFinite(n)) .{ .number = std.math.clamp(n, h.min, h.max) } else return,
        };
        _ = v.vm.callTop(h.f, if (input == .click) &.{} else &.{arg}) catch return v.stop(v.vm.message());
        v.render();
    }
};

/// The rendered value to a tree of nodes, within the limits.
pub const Parse = struct {
    v: *Visual,
    a: std.mem.Allocator,
    nodes: usize = 0,
    text_bytes: usize = 0,
    series: usize = 0,
    msg: []const u8 = "",

    pub const Fail = error{ Invalid, OutOfMemory };

    pub fn fail(p: *Parse, msg: []const u8) Fail {
        p.msg = msg;
        return error.Invalid;
    }

    pub fn text(p: *Parse, val: Value) Fail![]const u8 {
        var buf: [64]u8 = undefined;
        const t = switch (val) {
            .string => |s| s.bytes,
            .number => |n| if (std.math.isFinite(n)) luau.ops.formatNumber(&buf, n) else return p.fail("expected visual text or a finite number"),
            else => return p.fail("expected visual text or a finite number"),
        };
        p.text_bytes += t.len;
        if (p.text_bytes > max_text) return p.fail("visual text exceeds 8 KiB");
        return p.a.dupe(u8, t);
    }

    pub fn label(p: *Parse, t: *luau.value.Table) Fail![]const u8 {
        const l = t.getStr("label");
        return if (l == .nil) "" else p.text(l);
    }

    pub fn number(p: *Parse, val: Value) Fail!f64 {
        if (val != .number or !std.math.isFinite(val.number)) return p.fail("expected a finite number");
        return val.number;
    }

    pub fn handler(p: *Parse, t: *luau.value.Table, field: []const u8, h: Handler) Fail!?u32 {
        const f = t.getStr(field);
        if (f == .nil) return null;
        if (f != .function) return p.fail("visual handler must be a function");
        var copy = h;
        copy.f = f;
        try p.v.handlers.append(p.v.gpa, copy);
        return @intCast(p.v.handlers.items.len - 1);
    }

    /// The array part of `t`, with nothing else (dense, no holes).
    pub fn array(p: *Parse, t: *luau.value.Table, limit: usize, tagged: bool) Fail![]const Value {
        if (t.hash.count() > @intFromBool(tagged)) return p.fail("visual arrays must be dense, with no extra properties");
        if (t.array.items.len > limit) return p.fail("visual array exceeds its size limit");
        for (t.array.items) |x| if (x == .nil) return p.fail("visual arrays must be dense");
        return t.array.items;
    }

    pub fn node(p: *Parse, val: Value, depth: usize) Fail!Node {
        p.nodes += 1;
        if (depth > max_depth) return p.fail("visual depth exceeds 24");
        if (p.nodes > max_nodes) return p.fail("visual node count exceeds 512");
        if (val != .table) return p.fail("expected a ui node (the render function returns ui.column{…} or the like)");
        const t = val.table;
        const tag = t.getStr("__kind");
        if (tag != .string) return p.fail("expected a ui node kind");
        const kind = std.meta.stringToEnum(Kind, tag.string.bytes) orelse return p.fail("unsupported visual node kind");
        checkProperties(p.v.vm, t, kind) catch return p.fail("unsupported visual property (styling is not supported)");
        var n: Node = .{ .kind = kind };
        switch (kind) {
            .column, .row => {
                const items = try p.array(t, max_nodes, true);
                const children = try p.a.alloc(Node, items.len);
                for (items, children) |item, *c| c.* = try p.node(item, depth + 1);
                n.children = children;
            },
            .text => n.text = try p.text(t.getStr("text")),
            .stat => {
                n.label = try p.label(t);
                n.text = try p.text(t.getStr("value"));
            },
            .chart => {
                n.text = try p.label(t);
                const vals = t.getStr("values");
                if (vals != .table) return p.fail("expected an array table");
                const items = try p.array(vals.table, max_series, false);
                p.series += items.len;
                if (p.series > max_series) return p.fail("visual series exceeds 256 values");
                n.values = try p.a.alloc(f64, items.len);
                for (items, n.values) |x, *o| o.* = try p.number(x);
                const labels = t.getStr("labels");
                if (labels != .nil) {
                    if (labels != .table) return p.fail("expected an array table");
                    const ls = try p.array(labels.table, max_series, false);
                    if (ls.len != items.len) return p.fail("chart labels must match its values");
                    const out = try p.a.alloc([]const u8, ls.len);
                    for (ls, out) |x, *o| o.* = try p.text(x);
                    n.labels = out;
                }
            },
            .button => {
                n.text = try p.label(t);
                n.handler = try p.handler(t, "onClick", .{ .f = .nil, .expected = .click });
            },
            .toggle => {
                n.text = try p.label(t);
                const b = t.getStr("value");
                if (b != .boolean) return p.fail("toggle value must be a boolean");
                n.value = if (b.boolean) 1 else 0;
                n.handler = try p.handler(t, "onChange", .{ .f = .nil, .expected = .boolean });
            },
            .slider => {
                n.text = try p.label(t);
                n.min = try p.number(t.getStr("min"));
                n.max = try p.number(t.getStr("max"));
                n.value = try p.number(t.getStr("value"));
                if (n.min > n.max or n.value < n.min or n.value > n.max) return p.fail("invalid slider range or value");
                n.handler = try p.handler(t, "onChange", .{ .f = .nil, .expected = .number, .min = n.min, .max = n.max });
            },
            .rule => {},
            else => try more.parse(p, t, &n, depth),
        }
        return n;
    }
};

/// Whether a title and script are within what a visual may be.
pub fn validate(title: []const u8, script: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, title, " \t\r\n");
    if (t.len == 0 or (std.unicode.utf8CountCodepoints(title) catch max_title + 1) > max_title) return "visual title must be nonblank and at most 200 characters";
    if (std.mem.trim(u8, script, " \t\r\n").len == 0 or script.len > max_source) return "visual script must be nonblank and at most 64 KiB of UTF-8";
    return null;
}
