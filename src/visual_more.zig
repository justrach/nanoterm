//! nanoterm's own visual nodes, beyond Harness's: what explains a system
//! better than paragraphs. Headings and notes, a flow of steps (a pipeline,
//! clickable), tabs, lists, tables, code, badges, progress, and groups with
//! a title. Same rules: the host draws them, styling is refused.
const std = @import("std");
const visual = @import("visual.zig");
const luau = @import("luau/luau.zig");
const Node = visual.Node;
const Parse = visual.Parse;
const Table = luau.value.Table;

const max_steps = 12;
const max_options = 8;
const max_items = 64;
const max_columns = 8;
const max_rows = 64;

pub fn allowed(kind: visual.Kind) []const []const u8 {
    return switch (kind) {
        .heading, .note, .code => &.{"text"},
        .flow => &.{ "label", "steps", "active", "onSelect" },
        .tabs => &.{ "options", "value", "onChange" },
        .list => &.{ "items", "ordered" },
        .table => &.{ "columns", "rows" },
        .badge => &.{ "label", "tone" },
        .progress => &.{ "label", "value", "max" },
        .group => &.{"title"},
        else => &.{},
    };
}

/// An array of texts in field `name` of `t`, at most `limit` of them.
fn texts(p: *Parse, t: *Table, name: []const u8, limit: usize, required: bool) Parse.Fail![]const []const u8 {
    const v = t.getStr(name);
    if (v == .nil and !required) return &.{};
    if (v != .table) return p.fail("expected an array table");
    const items = try p.array(v.table, limit, false);
    const out = try p.a.alloc([]const u8, items.len);
    for (items, out) |x, *o| o.* = try p.text(x);
    return out;
}

/// A 1-based position among `n`, from field `name` (default 1).
fn position(p: *Parse, t: *Table, name: []const u8, n: usize) Parse.Fail!f64 {
    const v = t.getStr(name);
    if (v == .nil) return 1;
    const x = try p.number(v);
    if (x < 1 or x > @as(f64, @floatFromInt(@max(n, 1))) or x != @floor(x)) return p.fail("position out of range (positions start at 1)");
    return x;
}

pub fn parse(p: *Parse, t: *Table, n: *Node, depth: usize) Parse.Fail!void {
    switch (n.kind) {
        .heading, .note, .code => n.text = try p.text(t.getStr("text")),
        .flow => {
            n.text = try p.label(t);
            n.labels = try texts(p, t, "steps", max_steps, true);
            if (n.labels.len == 0) return p.fail("a flow needs steps");
            n.value = try position(p, t, "active", n.labels.len);
            n.handler = try p.handler(t, "onSelect", .{ .f = .nil, .expected = .number, .min = 1, .max = @floatFromInt(n.labels.len) });
        },
        .tabs => {
            n.labels = try texts(p, t, "options", max_options, true);
            if (n.labels.len == 0) return p.fail("tabs need options");
            n.value = try position(p, t, "value", n.labels.len);
            n.handler = try p.handler(t, "onChange", .{ .f = .nil, .expected = .number, .min = 1, .max = @floatFromInt(n.labels.len) });
        },
        .list => {
            n.labels = try texts(p, t, "items", max_items, true);
            const o = t.getStr("ordered");
            if (o != .nil and o != .boolean) return p.fail("ordered must be a boolean");
            n.ordered = o == .boolean and o.boolean;
        },
        .table => {
            n.labels = try texts(p, t, "columns", max_columns, true);
            const rows = t.getStr("rows");
            if (rows != .table) return p.fail("a table needs rows (an array of arrays)");
            const items = try p.array(rows.table, max_rows, false);
            const out = try p.a.alloc([]const []const u8, items.len);
            for (items, out) |r, *o| {
                if (r != .table) return p.fail("each table row is an array of cells");
                const cells = try p.array(r.table, max_columns, false);
                if (n.labels.len > 0 and cells.len != n.labels.len) return p.fail("table rows must have one cell per column");
                const row = try p.a.alloc([]const u8, cells.len);
                for (cells, row) |cell, *cw| cw.* = try p.text(cell);
                o.* = row;
            }
            n.rows = out;
        },
        .badge => {
            n.text = try p.label(t);
            const tone = t.getStr("tone");
            if (tone != .nil) {
                if (tone != .string) return p.fail("tone is one of neutral, accent, success, warning, danger");
                n.tone = std.meta.stringToEnum(visual.Tone, tone.string.bytes) orelse return p.fail("tone is one of neutral, accent, success, warning, danger");
            }
        },
        .progress => {
            n.text = try p.label(t);
            n.max = if (t.getStr("max") == .nil) 1 else try p.number(t.getStr("max"));
            n.value = try p.number(t.getStr("value"));
            if (n.max <= 0 or n.value < 0 or n.value > n.max) return p.fail("progress value must be within 0…max");
        },
        .group => {
            const title = t.getStr("title");
            n.text = if (title == .nil) "" else try p.text(title);
            // The children are the array part; the hash holds the kind and title.
            const items = t.array.items;
            if (items.len > 512) return p.fail("visual array exceeds its size limit");
            for (items) |x| if (x == .nil) return p.fail("visual arrays must be dense");
            const children = try p.a.alloc(Node, items.len);
            for (items, children) |item, *c| c.* = try p.node(item, depth + 1);
            n.children = children;
        },
        else => unreachable,
    }
}
