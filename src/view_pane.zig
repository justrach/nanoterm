//! One pane: a session's timeline of blocks and agent turns, and its input
//! at the bottom, in the manner of Warp's: a pane of Liquid Glass floating
//! over the timeline's end, which scrolls under it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
/// A key combination as this platform writes it.
const binds = @import("binds.zig");
const theme = @import("theme.zig");
const blocks = @import("blocks.zig");
const view_block = @import("view_block.zig");
const view_turn = @import("view_turn.zig");
const Session = @import("session.zig").Session;
const Workspace = @import("workspace.zig").Workspace;
const view_input = @import("view_input.zig");
const view_screen = @import("view_screen.zig");

/// The pane of `s` within `rect`; `focused` is the pane keys go to,
/// `dim` asks for unfocused panes to be dimmed (when several show).
pub fn pane(c: *ui.Context, w: *Workspace, s: *Session, rect: anytype, focused: bool, dim: bool) void {
    // The terminal is the pane's size: what a full-screen program fills.
    const size = view_screen.fit(c, rect.w, rect.h);
    s.fit(size[0], size[1]);
    ui.key(c, c.print("pane-{d}", .{s.id}));
    const p = ui.div(c).column().w(rect.w).h(rect.h).clip();
    defer p.end();
    if (s.shell.fullScreen()) |screen| {
        view_screen.draw(c, screen, focused);
    } else {
        s.sticky = null;
        const id = timeline(c, s);
        stickyHeader(c, s, id);
        composer(c, w, s, focused, rect.w, rect.h);
        jumpToLatest(c, s, id);
    }
    // Ghostty dims the panes the keys do not go to.
    if (dim and !focused) _ = c.leaf(.{ .absolute = true, .width = .fill, .height = .fill, .background = theme.background.alpha(0.35) }, .none, null);
}

/// The command of the block scrolled through, pinned to the timeline's
/// top as Warp pins it; a click goes to the block's start.
fn stickyHeader(c: *ui.Context, s: *Session, id: u64) void {
    const b = s.sticky orelse return;
    const box = c.rects.get(id) orelse return;
    const parent = c.rects.get(c.node(c.stack.items[c.stack.items.len - 1]).id) orelse return;
    const bar = ui.div(c).row().w(box.w).gap(8).itemsCenter().px(16).py(7).bg(theme.panel).border(theme.border).hover(theme.block_hover).control()
        .absolute().offset(box.x - parent.x, box.y - parent.y);
    defer bar.end();
    if (bar.clicked()) if (c.scroll.getPtr(id)) |sc| {
        sc.* = @max(0, sc.* + (s.sticky_y - box.y));
        c.changed = true;
    };
    ui.text(c, "❯", .{ .size = 12, .weight = .bold, .mono = true, .color = theme.accent });
    ui.text(c, b.command, .{ .size = 12.5, .weight = .semibold, .mono = true });
    ui.spacer(c);
    if (b.state == .running) {
        ui.text(c, view_block.spin(c), .{ .size = 12, .mono = true, .color = theme.accent });
    } else ui.text(c, view_block.duration(c, b.seconds()), .{ .size = 11, .mono = true, .color = if (b.failed()) theme.failure else theme.muted });
}

/// The input, over the timeline's bottom: placed by its height in the last
/// frame, and drawn again at once when that changes (a menu, a picture).
fn composer(c: *ui.Context, w: *Workspace, s: *Session, focused: bool, width: f32, height: f32) void {
    ui.key(c, "composer");
    const box = ui.div(c).column().w(width).absolute().offset(0, height - s.composer_h);
    defer box.end();
    view_input.panel(c, w, s, focused);
    if (c.rects.get(c.node(box.index).id)) |r| if (@abs(r.h - s.composer_h) > 0.5) {
        s.composer_h = r.h;
        c.frameIn(0);
    };
}

/// Scrolled up from the end while output comes: a pill back to it.
fn jumpToLatest(c: *ui.Context, s: *Session, id: u64) void {
    const max = c.scroll_max.get(id) orelse return;
    const at = c.scroll.get(id) orelse return;
    if (max - at < 160) return;
    const box = c.rects.get(id) orelse return;
    const parent = c.rects.get(c.node(c.stack.items[c.stack.items.len - 1]).id) orelse return;
    const pill = ui.div(c).row().gap(6).itemsCenter().px(12).py(6).rounded(14).bg(theme.block_selected).border(theme.border).hover(theme.block_hover).control()
        .shadow(.{ .color = .{ .a = 0.4 }, .blur = 12, .y = 4 }).absolute().offset(box.x - parent.x + box.w / 2 - 66, box.y - parent.y + box.h - s.composer_h - 46);
    defer pill.end();
    if (pill.clicked()) {
        // At the end, the timeline follows new output again.
        c.scroll.put(c.gpa, id, max) catch {};
        c.changed = true;
    }
    ui.icon(c, "chevron.down", .{ .size = 10, .color = theme.accent });
    ui.text(c, "Jump to latest", .{ .size = 12, .color = theme.text });
}

fn timeline(c: *ui.Context, s: *Session) u64 {
    // Its text selects with a drag and copies (⌘C), as a terminal's.
    // Room at the end for the input floating over it.
    const box = c.open(.{ .direction = .column, .width = .fill, .grow = 1, .scroll = true, .follow_end = true, .selectable = true, .padding = .{ .top = 4, .bottom = 12 + s.composer_h } }, null);
    defer c.end();
    const id = c.node(box).id;
    s.timeline_top = if (c.rects.get(id)) |r| r.y else null;
    // Just run or asked: into view once; then the reader's scroll unpins it.
    if (s.pin_jump == 2) {
        c.scroll.put(c.gpa, id, 1e9) catch {};
        s.pin_jump = 1;
    } else if (s.pin_jump == 1) {
        s.pin_jump = 0;
    } else if (s.pin != null and c.scrollMoved(id)) s.pin = null;
    defer scrollToMatch(c, s, id);
    if (s.timeline.items.len == 0) {
        welcome(c, s);
        return id;
    }
    for (s.timeline.items, 0..) |entry, i| {
        if (s.pin == i) pinMark(c, id);
        if (i > 0) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = theme.border }, .none, null);
        switch (entry) {
            .block => |b| view_block.block(c, s, b, false),
            .turn => |t| view_turn.turn(c, s, t),
        }
    }
    return id;
}

/// Where the pinned entry starts: the timeline follows no further than
/// putting it at the top.
fn pinMark(c: *ui.Context, box: u64) void {
    ui.key(c, "pin-mark");
    const m = c.leaf(.{ .width = .fill, .height = .{ .px = 0 } }, .none, null);
    const mark = c.rects.get(c.node(m).id) orelse return;
    const view = c.rects.get(box) orelse return;
    const offset = c.scroll.get(box) orelse 0;
    c.capScroll(box, mark.y - view.y + offset - 6);
}

/// The first thing a pane shows: what nanoterm is, things to try (a
/// click puts them in the input), and the keys worth knowing.
/// Find's current match moved: its block comes into view.
fn scrollToMatch(c: *ui.Context, s: *Session, id: u64) void {
    const f = &s.shared.find;
    const y = f.target_y orelse return;
    f.target_y = null;
    const box = c.rects.get(id) orelse return;
    const scroll = c.scroll.getPtr(id) orelse return;
    scroll.* = @max(0, scroll.* + (y - box.y) - 40);
    c.changed = true;
}

fn welcome(c: *ui.Context, s: *Session) void {
    const outer = ui.div(c).column().wFull().itemsCenter().pt(56).px(28);
    defer outer.end();
    const w = ui.div(c).column().wFull().maxW(680).gap(22);
    defer w.end();
    {
        const r = ui.div(c).row().gap(12).itemsCenter();
        defer r.end();
        ui.icon(c, "terminal.fill", .{ .size = 26, .color = theme.accent });
        ui.text(c, "nanoterm", .{ .size = 28, .weight = .bold });
    }
    ui.text(c, "Commands and questions in one input: nanoterm tells them apart, runs commands in blocks, and hands questions to a coding agent that works right here.", .{ .size = 14, .color = theme.muted, .wrap = true, .leading = 1.4 });
    section(c, "Try");
    {
        const r = ui.div(c).row().wFull().gap(8);
        defer r.end();
        const tries = [_]struct { icon: []const u8, text: []const u8, agent: bool }{
            .{ .icon = "chevron.right", .text = "git status", .agent = false },
            .{ .icon = "chevron.right", .text = "ls -la", .agent = false },
            .{ .icon = "sparkles", .text = "what does this project do?", .agent = true },
        };
        for (tries, 0..) |t, i| {
            ui.key(c, c.print("try-{d}", .{i}));
            const chip = ui.div(c).row().gap(7).itemsCenter().px(12).py(7).rounded(8).border(theme.border).hover(theme.block_hover).control();
            defer chip.end();
            if (chip.clicked()) {
                s.input.set(t.text);
                s.observe();
            }
            ui.icon(c, t.icon, .{ .size = 11, .color = if (t.agent) theme.agent else theme.accent });
            ui.text(c, t.text, .{ .size = 12.5, .mono = !t.agent });
        }
    }
    section(c, "Keys");
    {
        const keys = [_][2][]const u8{
            .{ "↩", "Run a command, or ask" },
            .{ binds.label("Cmd+I"), "Switch shell and agent" },
            .{ binds.label("Cmd+P"), "Every action, and your history" },
            .{ binds.label("Cmd+Shift+M"), "Choose the agent and its model" },
            .{ binds.label("Cmd+D"), "Split right" },
            .{ binds.label("Cmd+Shift+D"), "Split down" },
            .{ binds.label("Cmd+T"), "New tab" },
            .{ "Tab", "Complete files, commands, branches" },
        };
        var i: usize = 0;
        while (i < keys.len) : (i += 2) {
            const r = ui.div(c).row().wFull().gap(24);
            defer r.end();
            for (keys[i..@min(keys.len, i + 2)]) |k| {
                const cell = ui.div(c).row().gap(10).itemsCenter().grow().wFull();
                defer cell.end();
                {
                    const cap = ui.div(c).row().w(if (binds.mac) 44 else 110).justifyEnd();
                    defer cap.end();
                    ui.kbd(c, k[0]);
                }
                ui.text(c, k[1], .{ .size = 13, .color = theme.text.alpha(0.85) });
            }
        }
    }
    ui.text(c, "Agents speak ACP (graff, Claude Code). A failed command offers a fix; full-screen programs (vim, htop) draw in the pane.", .{ .size = 12, .color = theme.faint, .wrap = true });
    if (s.shell_exited) ui.text(c, "The shell exited.", .{ .size = 13, .color = theme.failure });
}

fn section(c: *ui.Context, title: []const u8) void {
    ui.text(c, title, .{ .size = 11, .weight = .semibold, .color = theme.faint });
}
