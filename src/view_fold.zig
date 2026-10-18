//! How a turn reads, as in Harness: the agent's working steps (thoughts,
//! tool calls, the commands it ran, and the narration between them) fold
//! into one line that says what it did ("Thought process · read 2 files ·
//! ran 1 command"); a click opens it. The reply (the text after the last
//! step), visuals, plans, questions and errors stay in view.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const agent_mod = @import("agent.zig");
const view_block = @import("view_block.zig");
const view_turn = @import("view_turn.zig");
const App = @import("session.zig").Session;
const Item = agent_mod.Item;

/// Where the reply starts: the text items after the last other item.
pub fn replyStart(items: []const Item) usize {
    var i = items.len;
    while (i > 0 and items[i - 1] == .text) i -= 1;
    return i;
}

/// Whether item `i` folds into a group.
pub fn folds(items: []const Item, i: usize, reply: usize) bool {
    return switch (items[i]) {
        .thought, .tool, .command => true,
        .text => i < reply,
        else => false,
    };
}

/// The agent's call of show_visual: the visual itself says it, once done.
pub fn isVisualTool(tl: *const agent_mod.Tool) bool {
    if (tl.status != .completed) return false;
    return std.mem.indexOf(u8, tl.title.items, "show_visual") != null or std.mem.indexOf(u8, tl.kind, "show_visual") != null;
}

/// Whether an item in a group shows anything (a visual's own tool call
/// and a command its tool already shows do not).
fn shown(t: *agent_mod.Turn, it: *const Item) bool {
    return switch (it.*) {
        .tool => |*tl| !isVisualTool(tl),
        .command => |b| !view_turn.shownByTool(t, b),
        else => true,
    };
}

fn plural(c: *ui.Context, n: usize, one: []const u8, many: []const u8) []const u8 {
    return c.print("{d} {s}", .{ n, if (n == 1) one else many });
}

/// What a group did, in Harness's words.
pub fn summary(c: *ui.Context, t: *agent_mod.Turn, items: []const Item) []const u8 {
    var reads: usize = 0;
    var edits: usize = 0;
    var commands: usize = 0;
    var searches: usize = 0;
    var fetches: usize = 0;
    var other: usize = 0;
    var thoughts: usize = 0;
    var notes: usize = 0;
    var failed: usize = 0;
    for (items) |*it| {
        if (!shown(t, it)) continue;
        switch (it.*) {
            .thought => thoughts += 1,
            .text => notes += 1,
            .command => commands += 1,
            .tool => |tl| {
                if (tl.status == .failed) failed += 1;
                const k = tl.kind;
                const eq = std.mem.eql;
                if (eq(u8, k, "read")) reads += 1 else if (eq(u8, k, "edit") or eq(u8, k, "delete") or eq(u8, k, "move")) edits += 1 else if (eq(u8, k, "execute")) commands += 1 else if (eq(u8, k, "search")) searches += 1 else if (eq(u8, k, "fetch")) fetches += 1 else if (eq(u8, k, "think")) thoughts += 1 else other += 1;
            },
            else => {},
        }
    }
    var parts: std.ArrayList([]const u8) = .empty;
    const a = c.alloc();
    if (thoughts == 1) parts.append(a, "thought process") catch {};
    if (thoughts > 1) parts.append(a, c.print("thought {d} times", .{thoughts})) catch {};
    if (notes == 1) parts.append(a, "wrote a note") catch {};
    if (notes > 1) parts.append(a, c.print("wrote {d} notes", .{notes})) catch {};
    if (commands > 0) parts.append(a, c.print("ran {s}", .{plural(c, commands, "command", "commands")})) catch {};
    if (edits > 0) parts.append(a, c.print("edited {s}", .{plural(c, edits, "file", "files")})) catch {};
    if (reads > 0) parts.append(a, c.print("read {s}", .{plural(c, reads, "file", "files")})) catch {};
    if (searches > 0) parts.append(a, c.print("searched {s}", .{plural(c, searches, "time", "times")})) catch {};
    if (fetches > 0) parts.append(a, c.print("fetched {s}", .{plural(c, fetches, "page", "pages")})) catch {};
    if (other > 0) parts.append(a, c.print("called {s}", .{plural(c, other, "tool", "tools")})) catch {};
    if (failed > 0) parts.append(a, c.print("{d} failed", .{failed})) catch {};
    if (parts.items.len == 0) return "";
    const joined = std.mem.join(a, " · ", parts.items) catch return "";
    if (joined.len > 0) joined[0] = std.ascii.toUpper(joined[0]);
    return joined;
}

/// Group `ordinal` of `t`, items [from, to): its line, and its steps when
/// open. `live` while the agent is still in it.
pub fn group(c: *ui.Context, app: *App, t: *agent_mod.Turn, from: usize, to: usize, ordinal: usize, live: bool) void {
    const items = t.items.items[from..to];
    const text = summary(c, t, items);
    if (text.len == 0 and !live) return;
    const bit: u64 = if (ordinal < 64) @as(u64, 1) << @intCast(ordinal) else 0;
    const open = t.open_groups & bit != 0;
    const col = ui.div(c).column().wFull().gap(10);
    defer col.end();
    {
        ui.key(c, c.print("fold-{d}", .{ordinal}));
        const it = ui.pressable(c, .{ .direction = .row, .gap = 8, .align_items = .center, .padding = .{ .top = 2, .bottom = 2 }, .control = true }, null);
        defer ui.end(c);
        if (it.clicked) {
            t.open_groups ^= bit;
            c.changed = true;
        }
        const color = if (it.hovered) theme.text else theme.muted;
        if (live) ui.text(c, view_block.spin(c), .{ .size = 12, .color = theme.agent, .mono = true });
        ui.text(c, if (text.len > 0) text else "Working", .{ .size = 13, .color = color });
        ui.icon(c, if (open) "chevron.down" else "chevron.right", .{ .size = 8.5, .weight = .semibold, .color = if (it.hovered) theme.muted else theme.faint });
    }
    if (!open) return;
    // The steps, on a rail.
    const r = ui.div(c).row().wFull().gap(14).itemsStretch().pl(3);
    defer r.end();
    _ = c.leaf(.{ .width = .{ .px = 1 }, .background = theme.border }, .none, null);
    const steps = ui.div(c).column().grow().gap(10);
    defer steps.end();
    for (items) |*it| if (shown(t, it)) view_turn.item(c, app, t, it);
}
