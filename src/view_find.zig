//! The find bar (⌘F), at the top right of the panes as editors have it:
//! what is searched, which match of how many, ↑ ↓ to step, ✕ to close.
//! ↩ goes to the next match, ⇧↩ the previous, esc closes.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const find = @import("find.zig");
const Workspace = @import("workspace.zig").Workspace;

/// This frame's matches in the focused pane, for the blocks to draw.
pub fn prepare(c: *ui.Context, w: *Workspace) void {
    const shared = w.shared;
    const target = shared.find.target_y;
    shared.find = .{};
    if (!w.finding) return;
    const query = w.find.text();
    const s = w.focused();
    const matches = find.collect(c.alloc(), s.timeline.items, query);
    if (matches.len > 0) w.find_index %= matches.len else w.find_index = 0;
    shared.find = .{ .session = s.id, .query = query, .matches = matches, .current = w.find_index, .target_y = target };
    if (w.find_scroll) {
        w.find_scroll = false;
        if (shared.find.currentMatch()) |m| shared.find.scroll_to = m.block;
    }
}

/// Keys while the bar shows; true if one was taken.
pub fn keys(c: *ui.Context, w: *Workspace) bool {
    const S = ui.Shortcut;
    if (!w.finding) return false;
    if (c.shortcut(.{ .key = S.escape })) {
        w.closeFind();
        return true;
    }
    if (c.shortcut(.{ .key = S.enter, .shift = true })) {
        step(w, -1);
        return true;
    }
    return false;
}

fn step(w: *Workspace, by: i32) void {
    const n = w.shared.find.matches.len;
    if (n == 0) return;
    const cur: i64 = @intCast(w.find_index);
    w.find_index = @intCast(@mod(cur + by, @as(i64, @intCast(n))));
    w.find_scroll = true;
}

pub fn bar(c: *ui.Context, w: *Workspace, top: f32) void {
    if (!w.finding) return;
    const f = &w.shared.find;
    const width: f32 = 380;
    ui.key(c, "find-bar");
    const b = ui.div(c).row().w(width).gap(8).itemsCenter().px(10).py(6).bg(theme.panel).rounded(9).border(theme.border)
        .shadow(.{ .color = .{ .a = 0.45 }, .blur = 18, .y = 6 }).absolute().offset(c.size.w - width - 16, top + 8);
    defer b.end();
    ui.icon(c, "magnifyingglass", .{ .size = 11, .color = theme.muted });
    {
        const field = ui.div(c).row().grow();
        defer field.end();
        const id = c.peekId(null);
        c.focus = id;
        const r = ui.textField(c, &w.find, .{ .placeholder = "Find in blocks", .width = .fill, .size = 13 });
        if (r.changed) {
            w.find_index = 0;
            w.find_scroll = true;
        }
        if (r.submitted) step(w, 1);
    }
    const count = if (f.query.len == 0) "" else if (f.matches.len == 0) "no matches" else c.print("{d} of {d}", .{ f.current + 1, f.matches.len });
    ui.text(c, count, .{ .size = 11.5, .color = if (f.query.len > 0 and f.matches.len == 0) theme.failure else theme.muted });
    if (ui.button(c, "", .{ .variant = .ghost, .size = 10, .icon = "chevron.up" }).clicked) step(w, -1);
    if (ui.button(c, "", .{ .variant = .ghost, .size = 10, .icon = "chevron.down" }).clicked) step(w, 1);
    if (ui.button(c, "", .{ .variant = .ghost, .size = 10, .icon = "xmark" }).clicked) w.closeFind();
}
