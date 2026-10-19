//! A block as Warp shows one: where and when it ran, the command, its
//! output in color, how it ended; a bar on the left tells running,
//! succeeded or failed at a glance.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const blocks = @import("blocks.zig");
const App = @import("session.zig").Session;
const assist = @import("assist.zig");
const find = @import("find.zig");
const view_markdown = @import("view_markdown.zig");

/// Find, for the panes not searched.
var no_find: find.State = .{};

/// Output lines shown before "show all".
const tail_lines = 400;
/// Markdown longer than this stays text: it is parsed every frame.
const markdown_lines = 3000;
const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

pub const mono: ui.TextStyle = .{ .size = 12.5, .mono = true };

/// A duration, in the frame's memory.
pub fn duration(c: *ui.Context, seconds: f64) []const u8 {
    if (seconds < 1) return c.print("{d:.0}ms", .{seconds * 1000});
    if (seconds < 60) return c.print("{d:.1}s", .{seconds});
    const s: u64 = @intFromFloat(seconds);
    return c.print("{d}m {d:0>2}s", .{ s / 60, s % 60 });
}

pub fn spin(c: *ui.Context) []const u8 {
    // Its next step, not every refresh: the window is drawn 12 times a
    // second while something runs, not 120.
    c.frameIn(1.0 / 12.0);
    const i: usize = @intFromFloat(@mod(c.time * 12, spinner.len));
    return spinner[i];
}

/// A block; `nested` inside an agent's turn, drawn more quietly.
pub fn block(c: *ui.Context, app: *App, b: *blocks.Block, nested: bool) void {
    ui.key(c, c.print("block-{d}", .{b.id}));
    const selected = app.selected == b.id;
    var d = ui.div(c).column().wFull().px(if (nested) 12 else 16).py(if (nested) 8 else 12).gap(6);
    d = if (nested) d.bg(theme.background).rounded(8).border(theme.border) else if (selected) d.bg(theme.block_selected) else d.hover(theme.block_hover);
    defer d.end();
    const it = d.interaction();
    if (d.clicked() and !nested) app.selected = if (selected) null else b.id;
    // Its header went above the timeline while its output shows: pinned.
    if (!nested) if (it.rect) |r| if (app.timeline_top) |top| {
        if (r.y < top - 4 and r.y + r.h > top + 80) {
            app.sticky = b;
            app.sticky_y = r.y;
        }
    };
    // Find's current match is here: say where, for the timeline to scroll.
    const f = if (app.shared.find.session == app.id) &app.shared.find else &no_find;
    if (f.scroll_to == b.id) if (it.rect) |r| {
        f.target_y = r.y;
        f.scroll_to = null;
    };

    // The bar on the left: running, failed, done.
    const bar = if (b.state == .running) theme.accent else if (b.failed()) theme.failure else if (selected) theme.accent else theme.border;
    _ = c.leaf(.{ .absolute = true, .width = .{ .px = 3 }, .height = .fill, .radius = 1.5, .background = bar, .offset = .{ .x = if (nested) -8 else -10 } }, .none, null);

    header(c, app, b, it.hovered);
    {
        const r = ui.div(c).row().gap(8).itemsCenter();
        defer r.end();
        ui.text(c, if (b.source == .agent) "⚡" else "❯", .{ .size = 13, .weight = .bold, .color = if (b.source == .agent) theme.agent else theme.accent, .mono = true });
        ui.richText(c, b.command, find.spansFor(c.alloc(), f, &.{}, b.id, find.command), .{ .size = 13, .weight = .semibold, .mono = true, .wrap = true });
    }
    output(c, b, f);
    if (!nested) @import("view_remote.zig").bar(c, app, b);
    // A failed command: the agent can find out why, or fix it.
    if (!nested and b.state == .done and b.failed() and b.source == .shell) {
        const r = ui.div(c).row().gap(8).itemsCenter().pt(2);
        defer r.end();
        const fix = c.print("Fix with {s}", .{app.which.label()});
        if (ui.button(c, fix, .{ .variant = .secondary, .size = 12, .icon = "wand.and.stars" }).clicked) assist.askAbout(app, b, .fix);
        if (ui.button(c, "Explain", .{ .variant = .ghost, .size = 12, .icon = "questionmark.circle" }).clicked) assist.askAbout(app, b, .explain);
    }
}

fn header(c: *ui.Context, app: *App, b: *blocks.Block, hovered: bool) void {
    const r = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer r.end();
    ui.text(c, blocks.tildePath(c.alloc(), b.cwd, app.home), .{ .size = 11.5, .mono = true, .color = theme.cwd });
    if (b.git_branch.len > 0) {
        ui.icon(c, "arrow.triangle.branch", .{ .size = 10, .color = theme.branch });
        ui.text(c, b.git_branch, .{ .size = 11.5, .mono = true, .color = theme.branch });
    }
    if (b.source == .agent) ui.badge(c, "agent", theme.agent);
    ui.spacer(c);
    if (hovered and b.state == .done and b.source == .shell) {
        // Warp's block actions: run again, ask the agent, copy.
        if (ui.button(c, "", .{ .variant = .ghost, .size = 11, .icon = "arrow.clockwise" }).clicked) app.run(b.command);
        if (ui.button(c, "", .{ .variant = .ghost, .size = 11, .icon = "sparkles" }).clicked) {
            app.selected = b.id;
            app.lock = .agent;
        }
        if (ui.button(c, "", .{ .variant = .ghost, .size = 11, .icon = "text.cursor" }).clicked) nanoui.clipboard.writeText(b.command);
    }
    if (hovered and rendersMarkdown(b, null)) {
        const icon = if (b.raw) "doc.richtext" else "chevron.left.forwardslash.chevron.right";
        if (ui.button(c, if (b.raw) "Rendered" else "Raw", .{ .variant = .ghost, .size = 11, .icon = icon }).clicked) b.raw = !b.raw;
    }
    if (hovered and b.output.lineCount() > 0) {
        if (ui.button(c, "", .{ .variant = .ghost, .size = 11, .icon = "doc.on.doc" }).clicked) {
            const text = b.output.plainText(app.gpa) catch return;
            defer app.gpa.free(text);
            nanoui.clipboard.writeText(text);
        }
    }
    switch (b.state) {
        .running => {
            ui.text(c, spin(c), .{ .size = 12, .color = theme.accent, .mono = true });
            ui.text(c, duration(c, b.seconds()), .{ .size = 11.5, .color = theme.muted, .mono = true });
        },
        .done => {
            const ok = !b.failed();
            ui.icon(c, if (ok) "checkmark" else "xmark", .{ .size = 10, .weight = .bold, .color = if (ok) theme.success else theme.failure });
            if (!ok) ui.text(c, c.print("{d}", .{b.exit_code orelse 0}), .{ .size = 11.5, .mono = true, .color = theme.failure });
            ui.text(c, duration(c, b.seconds()), .{ .size = 11.5, .color = theme.muted, .mono = true });
        },
    }
}

/// Whether the block printed a Markdown file (`cat README.md`) that can
/// be drawn as Markdown; with `f`, also whether it is (not raw, not where
/// Find's current match is, which needs the lines).
fn rendersMarkdown(b: *const blocks.Block, f: ?*const find.State) bool {
    if (b.state != .done or b.failed() or b.output.alternate_screen) return false;
    const count = b.output.lineCount();
    if (count == 0 or count > markdown_lines or b.output.dropped > 0) return false;
    if (blocks.markdownFile(b.command) == null) return false;
    const st = f orelse return true;
    if (b.raw) return false;
    if (st.currentMatch()) |m| if (m.block == b.id) return false;
    return true;
}

fn output(c: *ui.Context, b: *blocks.Block, f: *const find.State) void {
    const lines = b.output.lines.items;
    const count = b.output.lineCount();
    if (count == 0) return;
    if (rendersMarkdown(b, f)) {
        const text = b.output.plainText(c.alloc()) catch "";
        const box = ui.div(c).column().wFull().pt(4).pb(2);
        defer box.end();
        // Its pictures are beside the file.
        const file = blocks.markdownFile(b.command) orelse "";
        const path = std.fs.path.join(c.alloc(), &.{ b.cwd, file }) catch "";
        view_markdown.markdownIn(c, text, std.fs.path.dirname(path));
        return;
    }
    // The current match in lines not shown: show them all.
    if (f.currentMatch()) |m| if (m.block == b.id and m.line != find.command and count > tail_lines and m.line < count - tail_lines) {
        b.expanded = true;
    };
    const first = if (b.expanded or count <= tail_lines) 0 else count - tail_lines;
    const col = ui.div(c).column().wFull().gap(0);
    defer col.end();
    if (first > 0 or b.output.dropped > 0) {
        const hidden = first + b.output.dropped;
        if (ui.button(c, c.print("Show {d} earlier lines", .{hidden}), .{ .variant = .ghost, .size = 11.5, .icon = "chevron.up" }).clicked) b.expanded = true;
    }
    for (lines[first..count], first..) |*l, i| {
        var style = mono;
        style.wrap = true;
        style.color = theme.text;
        ui.richText(c, l.text.items, find.spansFor(c.alloc(), f, l.spans.items, b.id, i), style);
    }
    if (b.expanded and count > tail_lines) {
        if (ui.button(c, "Show less", .{ .variant = .ghost, .size = 11.5, .icon = "chevron.down" }).clicked) b.expanded = false;
    }
}
