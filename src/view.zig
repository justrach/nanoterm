//! nanoterm's window: the title strip (tabs, the agent picker), and the
//! active tab's panes laid out from its split tree, with dividers that
//! drag (double-click equalizes) — Ghostty's splits, Warp's blocks.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
/// A key combination as this platform writes it.
const K = ui.keys.label;
const binds = @import("binds.zig");
const theme = @import("theme.zig");
const split = @import("split.zig");
const agent_mod = @import("agent.zig");
const view_pane = @import("view_pane.zig");
const view_overlay = @import("view_overlay.zig");
const view_find = @import("view_find.zig");
const assist = @import("assist.zig");
const program = @import("session_program.zig");
const program_pager = @import("pager.zig");
const ws_mod = @import("workspace.zig");
const Workspace = ws_mod.Workspace;
const Node = ws_mod.Node;
const Tree = ws_mod.Tree;

const title_height = 40;

pub fn view(w: *Workspace, c: *ui.Context) void {
    if (w.tabs.items.len == 0) return;
    focusOnPress(w, c);
    // Harness's palettes: light, dark, or as the system is.
    const want: theme.Appearance = switch (w.shared.appearance) {
        .system => if (nanoui.isDark()) .dark else .light,
        .dark => .dark,
        .light => .light,
    };
    if (want != theme.appearance) theme.apply(want);
    c.theme = theme.ui();
    c.setZoom(w.zoom);
    shortcuts(w, c);
    view_find.prepare(c, w);
    const root = ui.div(c).column().sizeFull().bg(theme.background);
    defer root.end();
    titleBar(w, c);
    const t = w.tab();
    const area: split.Rect = .{ .x = 0, .y = title_height, .w = c.size.w, .h = c.size.h - title_height };
    w.placed.clearRetainingCapacity();
    if (t.zoomed) {
        place(w, t.focused, area);
        view_pane.pane(c, w, t.session(), area, true, false);
    } else {
        const several = t.tree.root.kind == .split;
        node(w, c, t.tree.root, area, several);
    }
    view_find.bar(c, w, title_height);
    @import("view_update.zig").card(c, w, title_height);
    view_overlay.overlay(c, w);
    // The text size is kept for the next launch.
    w.shared.prefs.setZoom(w.zoom);
}

/// A press in a pane focuses it, before anything in it handles the press.
fn focusOnPress(w: *Workspace, c: *ui.Context) void {
    if (!c.input.pressed or w.overlay != .none) return;
    const m = c.input.mouse;
    for (w.placed.items) |p| {
        const r = p.rect;
        if (m.x >= r.x and m.y >= r.y and m.x < r.x + r.w and m.y < r.y + r.h) {
            w.focus(p.node);
            return;
        }
    }
}

/// The keys a pane takes before its input does: an open panel's first,
/// then the completion menu's, then the pane's.
fn shortcuts(w: *Workspace, c: *ui.Context) void {
    const S = ui.Shortcut;
    const s = w.focused();
    // Onboarding is answered, not dismissed.
    if (w.overlay == .onboarding) {
        _ = c.shortcut(.{ .key = S.escape });
        return;
    }
    if (c.shortcut(binds.shortcut("Cmd+P")) or c.shortcut(binds.shortcut("Cmd+Shift+P"))) w.openPalette();
    if (c.shortcut(binds.shortcut("Cmd+Shift+M"))) w.openModels();
    if (w.overlay != .none) {
        if (c.shortcut(.{ .key = S.up })) w.pick -|= 1;
        if (c.shortcut(.{ .key = S.down })) w.pick += 1;
        if (c.shortcut(.{ .key = S.escape })) w.closeOverlay();
        if (w.overlay == .palette) {
            const all = std.enums.values(@import("palette.zig").Scope);
            const at = @intFromEnum(w.scope);
            if (c.shortcut(.{ .key = S.tab, .shift = true })) {
                w.scope = all[(at + all.len - 1) % all.len];
                w.pick = 0;
            } else if (c.shortcut(.{ .key = S.tab })) {
                w.scope = all[(at + 1) % all.len];
                w.pick = 0;
            }
        }
        _ = c.shortcut(.{ .key = S.tab });
        return;
    }
    if (c.shortcut(binds.shortcut("Cmd+F"))) w.openFind();
    // Where ⌃C stops the command, Ctrl+Shift+C copies what is selected
    // (⌘C comes through the Edit menu's Copy on the Mac).
    if (!binds.mac and c.selection.text.items.len > 0 and c.shortcut(binds.shortcut("Cmd+C"))) c.clipboard.write(c.clipboard.ctx, c.selection.text.items);
    if (c.shortcut(binds.shortcut("Cmd+="))) w.zoomBy(0.1);
    if (c.shortcut(binds.shortcut("Cmd+-"))) w.zoomBy(-0.1);
    if (c.shortcut(binds.shortcut("Cmd+0"))) w.zoom = 1;
    if (view_find.keys(c, w)) return;
    // Inside a block's output, the keys are the pager's.
    if (program_pager.open) |pg| if (pg.session == s) return program_pager.keys(c, pg);
    // A full-screen program takes the keys, ⌘ combinations aside.
    if (s.shell.fullScreen()) |screen| return @import("view_screen.zig").keys(c, s, screen);
    pasteImage(c, s);
    if (c.shortcut(binds.shortcut("Cmd+I"))) s.toggleMode();
    if (c.shortcut(binds.shortcut("Cmd+K"))) s.clear();
    if (c.shortcut(.{ .key = 'c', .ctrl = true })) s.interrupt();
    // ^D on an empty input: the program's end of input, as in a terminal.
    if (s.input.len == 0 and program.reading(s) and c.shortcut(.{ .key = 'd', .ctrl = true })) program.eof(s);
    if (c.shortcut(binds.shortcut("Cmd+Up"))) selectBlock(s, -1);
    if (c.shortcut(binds.shortcut("Cmd+Down"))) selectBlock(s, 1);
    if (s.menu.open) {
        if (c.shortcut(.{ .key = S.up })) s.menu.move(-1);
        if (c.shortcut(.{ .key = S.down })) s.menu.move(1);
        if (c.shortcut(.{ .key = S.tab })) assist.accept(s);
        if (c.shortcut(.{ .key = S.escape })) {
            s.menu.close();
            s.menu.dismissed = true;
        }
        return;
    }
    if (c.shortcut(.{ .key = S.tab })) assist.tab(s, s.caret);
    // ↑ on the input's first line, ↓ on its last: the history; else the
    // input moves between its lines.
    if (s.input_lines[0] == 0 and c.shortcut(.{ .key = S.up })) s.historyStep(true);
    if (s.input_lines[0] + 1 >= s.input_lines[1] and c.shortcut(.{ .key = S.down })) s.historyStep(false);
    const keys = w.shared.prefs.keys;
    // Emacs's ^P and ^N: the history, as readline has them.
    if (keys == .emacs) {
        // M-v, a page up: into the output above.
        if (c.shortcut(.{ .key = 'v', .alt = true })) if (program_pager.target(s)) |b| program_pager.enter(s, b);
        if (c.shortcut(.{ .key = 'p', .ctrl = true })) s.historyStep(true);
        if (c.shortcut(.{ .key = 'n', .ctrl = true })) s.historyStep(false);
    }
    // Vim's Esc in insert mode is the input's (to normal mode).
    if (keys == .vim and s.vim == .insert) return;
    if (c.shortcut(.{ .key = S.escape })) {
        if (s.agent) |ag| if (ag.status == .working) return ag.cancel();
        if (s.selected != null) {
            s.selected = null;
        } else if (s.input.len == 0) s.lock = null;
    }
}

/// ⌘V with a picture on the clipboard attaches it; text is left for the
/// input to paste.
fn pasteImage(c: *ui.Context, s: *@import("session.zig").Session) void {
    const want = (ui.Shortcut{ .key = 'v', .cmd = true }).native();
    const k = (c.input.shortcut orelse return).native();
    if (k.key != want.key or k.cmd != want.cmd or k.ctrl != want.ctrl or k.alt or k.shift) return;
    if (s.shell.busy()) return;
    if (@import("attach.zig").paste(&s.attachments, s.io)) _ = c.shortcut(want);
}

/// ⌘↑ ⌘↓: selects the block before or after the selected one.
fn selectBlock(s: *@import("session.zig").Session, by: i32) void {
    var ids: [512]u64 = undefined;
    var n: usize = 0;
    for (s.timeline.items) |e| switch (e) {
        .block => |b| if (n < ids.len) {
            ids[n] = b.id;
            n += 1;
        },
        .turn => {},
    };
    if (n == 0) return;
    var at: i64 = if (by < 0) @intCast(n) else -1;
    if (s.selected) |sel| for (ids[0..n], 0..) |id, i| if (id == sel) {
        at = @intCast(i);
    };
    const next = std.math.clamp(at + by, 0, @as(i64, @intCast(n - 1)));
    s.selected = ids[@intCast(next)];
}

fn place(w: *Workspace, n: *Node, r: split.Rect) void {
    w.placed.append(w.shared.gpa, .{ .node = n, .rect = r }) catch {};
}

fn node(w: *Workspace, c: *ui.Context, n: *Node, r: split.Rect, several: bool) void {
    switch (n.kind) {
        .leaf => |s| {
            place(w, n, r);
            view_pane.pane(c, w, s, r, n == w.tab().focused, several);
        },
        .split => |*sp| {
            const parts = Tree.parts(sp.*, r);
            const box = if (sp.axis == .horizontal) ui.div(c).row().w(r.w).h(r.h) else ui.div(c).column().w(r.w).h(r.h);
            defer box.end();
            node(w, c, sp.first, parts[0], several);
            divider(w, c, n, r, parts[1]);
            node(w, c, sp.second, parts[2], several);
        },
    }
}

/// A divider: drag it to resize the split, double-click to equalize.
fn divider(w: *Workspace, c: *ui.Context, n: *Node, split_rect: split.Rect, r: split.Rect) void {
    const sp = &n.kind.split;
    const horizontal = sp.axis == .horizontal;
    var d = ui.div(c).w(r.w).h(r.h);
    d = if (horizontal) d.row().justifyCenter() else d.column().justifyCenter();
    defer d.end();
    const it = d.interaction();
    const active = it.hovered or it.pressed;
    if (active) c.cursor = if (horizontal) .resize_left_right else .resize_up_down;
    if (it.pressed and c.input.pressed and c.input.click_count >= 2) {
        Tree.equalize(w.tab().tree.root);
        c.changed = true;
    } else if (it.pressed) {
        const m = c.input.mouse;
        const along = if (horizontal) (m.x - split_rect.x - split.divider / 2) / (split_rect.w - split.divider) else (m.y - split_rect.y - split.divider / 2) / (split_rect.h - split.divider);
        sp.ratio = std.math.clamp(along, 0.1, 0.9);
        c.changed = true;
    }
    const color = if (active) theme.accent else theme.border;
    if (horizontal) {
        _ = c.leaf(.{ .width = .{ .px = 1 }, .height = .fill, .background = color }, .none, null);
    } else {
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = color }, .none, null);
    }
}

fn titleBar(w: *Workspace, c: *ui.Context) void {
    const s = w.focused();
    // Under the hidden title bar: the traffic lights sit on the left.
    const bar = ui.div(c).row().wFull().h(title_height).gap(8).itemsCenter().px(16).bg(theme.background);
    defer bar.end();
    _ = c.leaf(.{ .width = .{ .px = 62 } }, .none, null);
    if (w.tabs.items.len > 1) {
        tabs(w, c);
    } else {
        ui.text(c, "nanoterm", .{ .size = 13, .weight = .semibold });
        ui.text(c, s.title(), .{ .size = 12, .color = theme.muted, .mono = true });
    }
    ui.spacer(c);
    if (s.agent) |ag| statusDot(c, ag.status);
    if (w.updater) |u| if (u.ready()) |version| if (!@import("view_update.zig").showing(w)) update(w, c, u, version);
    // Settings, for those who reach for the mouse.
    ui.key(c, "settings-button");
    if (ui.button(c, "", .{ .variant = .ghost, .size = 11, .icon = "gearshape" }).clicked) w.openSettings();
    // The palette, for those who reach for the mouse.
    ui.key(c, "palette-button");
    const b = ui.div(c).row().gap(6).itemsCenter().px(10).py(4).rounded(7).border(theme.border).hover(theme.block_hover);
    defer b.end();
    if (b.clicked()) w.openPalette();
    ui.icon(c, "magnifyingglass", .{ .size = 10, .color = theme.muted });
    ui.text(c, "Commands", .{ .size = 11.5, .color = theme.muted });
    ui.kbd(c, binds.label("Cmd+P"));
}

/// A newer nanoterm, downloaded and checked: restart into it.
fn update(w: *Workspace, c: *ui.Context, u: *nanoui.Updater, version: []const u8) void {
    const on = c.theme.accent_text;
    ui.key(c, "update-button");
    const b = ui.div(c).row().gap(6).itemsCenter().px(10).py(4).rounded(7).bg(theme.accent).hover(c.theme.accent_hover);
    defer b.end();
    if (b.clicked()) if (u.restart()) w.nanoapp.quit();
    ui.icon(c, "arrow.down.circle.fill", .{ .size = 11, .color = on });
    ui.text(c, c.print("Restart to update to {s}", .{version}), .{ .size = 11.5, .weight = .semibold, .color = on });
}

/// Ghostty's tab bar: a title per tab, its number for ⌘1…⌘9, a close
/// button on the one under the pointer, and "+" for a new one.
fn tabs(w: *Workspace, c: *ui.Context) void {
    var close: ?usize = null;
    for (w.tabs.items, 0..) |t, i| {
        const active = i == w.active;
        ui.key(c, c.print("tab-{x}", .{@intFromPtr(t)}));
        var pill = ui.div(c).row().gap(6).itemsCenter().px(10).py(4).rounded(7).maxW(220).clip();
        pill = if (active) pill.bg(theme.block_selected) else pill.hover(theme.block_hover);
        defer pill.end();
        const it = pill.interaction();
        if (pill.clicked()) w.selectTab(i);
        if (i < 9) ui.text(c, c.print("{s}{d}", .{ if (binds.mac) "⌘" else "Alt+", i + 1 }), .{ .size = 10.5, .color = theme.faint });
        const panes = Tree.count(t.tree.root);
        ui.text(c, t.session().title(), .{ .size = 12, .weight = if (active) .semibold else .regular, .color = if (active) theme.text else theme.muted });
        if (panes > 1) ui.text(c, c.print("{d}", .{panes}), .{ .size = 10.5, .color = theme.faint });
        if (it.hovered or active) {
            if (ui.button(c, "", .{ .variant = .ghost, .size = 9, .icon = "xmark" }).clicked) close = i;
        }
    }
    if (ui.button(c, "", .{ .variant = .ghost, .size = 11, .icon = "plus" }).clicked) {
        _ = w.newTab(w.focused().cwd()) catch {};
    }
    if (close) |i| w.closeTab(i);
}

fn statusDot(c: *ui.Context, status: agent_mod.Status) void {
    const color: ui.Color = switch (status) {
        .off => theme.faint,
        .starting => theme.warning,
        .ready => theme.success,
        .working => theme.agent,
        .failed => theme.failure,
    };
    _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = color }, .none, null);
    ui.text(c, @tagName(status), .{ .size = 11.5, .color = theme.muted });
}
