//! A pane's input, as Warp's: chips for where you are (folder, branch,
//! what runs, the block given as context) and the agent and model (click
//! to choose), then one input that knows commands from requests — a pill
//! shows which it took, and why (auto, Jev, or chosen) — with the history's
//! suggestion drawn after the caret and a completion menu above it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
/// A key combination as this platform writes it.
const binds = @import("binds.zig");
const theme = @import("theme.zig");
const blocks = @import("blocks.zig");
const assist = @import("assist.zig");
const complete = @import("complete.zig");
const attach = @import("attach.zig");
const Session = @import("session.zig").Session;
const Workspace = @import("workspace.zig").Workspace;

/// Rows of the completion menu shown at once.
const menu_rows = 8;

pub fn panel(c: *ui.Context, w: *Workspace, s: *Session, focused: bool) void {
    const p = ui.div(c).column().wFull();
    defer p.end();
    {
        // Floating, with room under it to the window's edge.
        const top = ui.div(c).column().wFull().px(16).pt(6).pb(16).gap(7);
        defer top.end();
        if (focused and s.menu.open) menu(c, s);
        // Harness's composer: a rounded pill, the pictures, the text, and
        // a row of controls with the send button at its end, of Liquid
        // Glass that what scrolls under it shows through.
        const pill = ui.div(c).column().wFull().gap(10).px(16).pt(14).pb(10).rounded(26).glass(.{}).border(theme.border.alpha(0.6));
        defer pill.end();
        pictures(c, s);
        // The focused pane's input has the keyboard, unless a panel is open.
        s.input_id = c.peekId(null);
        if (focused and w.overlay == .none and !w.finding) c.focus = s.input_id;
        const placeholder = if (s.shell.remoteReady())
            c.print("Run on {s}, or ask {s} — it works there too", .{ s.shell.remote.?.host, s.which.label() })
        else if (s.shell.busy())
            "Input for the running command"
        else if (s.lock == .agent)
            c.print("Ask {s} — it can read, edit and run commands here", .{s.which.label()})
        else if (s.lock == .terminal)
            "Run a command"
        else
            "Run a command, or ask the agent anything";
        const result = ui.textField(c, &s.input, .{ .placeholder = placeholder, .width = .fill, .size = 14.5, .bare = true, .suggestion = if (focused) assist.suggestion(s) else "", .keys = w.shared.prefs.keys });
        s.caret = result.caret;
        s.vim = if (result.vim_visual) .visual else if (result.vim_normal) .normal else .insert;
        // Vim's j and k in normal mode: through the history.
        if (result.history != 0) s.historyStep(result.history < 0);
        if (result.changed) {
            s.history_pos = null;
            assist.typed(s, result.caret);
        }
        if (result.submitted) {
            if (s.menu.open) assist.accept(s) else s.submit();
        }
        s.observe();
        assist.refresh(s);
        actions(c, w, s);
    }
}

/// The pill's controls: attach, where Return goes, the agent and model,
/// and the round send button (a stop square while something runs).
fn actions(c: *ui.Context, w: *Workspace, s: *Session) void {
    const r = ui.div(c).row().wFull().gap(8).itemsCenter();
    defer r.end();
    {
        ui.key(c, "attach");
        const b = ui.div(c).row().size(28, 28).roundedFull().center().hover(theme.text.alpha(0.08));
        defer b.end();
        if (b.clicked() and !s.shell.busy()) attach.choose(w);
        ui.icon(c, "paperclip", .{ .size = 13, .color = theme.muted });
    }
    modePill(c, s);
    // Vim's mode, as its -- INSERT -- line shows it: Esc for normal mode.
    if (w.shared.prefs.keys == .vim) {
        const insert = s.vim == .insert;
        const d = ui.div(c).row().px(8).py(3).rounded(6).bg(theme.accent.alpha(if (insert) 0.07 else 0.16));
        defer d.end();
        ui.text(c, switch (s.vim) {
            .insert => "INSERT",
            .normal => "NORMAL",
            .visual => "VISUAL",
        }, .{ .size = 10.5, .weight = .bold, .mono = true, .color = theme.accent });
    }
    if (s.mode() == .agent) if (assist.attached(s)) |b| {
        // The selected block goes with the prompt; ✕ leaves it out.
        const d = ui.div(c).row().gap(5).itemsCenter().px(8).py(3).roundedFull().bg(theme.agent.alpha(0.12));
        defer d.end();
        ui.icon(c, "paperclip", .{ .size = 10, .color = theme.agent });
        ui.text(c, c.print("{s}", .{b.command[0..@min(b.command.len, 32)]}), .{ .size = 11.5, .mono = true, .color = theme.agent });
        if (ui.button(c, "", .{ .variant = .ghost, .size = 8.5, .icon = "xmark" }).clicked) s.selected = null;
    };
    ui.spacer(c);
    modelChip(c, w, s);
    // Send, or stop what runs.
    // An SSH session open is not something running: its commands are.
    const remote_idle = s.shell.remoteReady();
    const running = (s.shell.busy() and !remote_idle) or (if (s.agent) |ag| ag.status == .working else false);
    const can_send = s.input.len > 0 or s.attachments.items.items.len > 0;
    ui.key(c, "send");
    var send = ui.div(c).row().size(30, 30).roundedFull().center().bg(theme.text);
    if (!running and !can_send) send = send.opacity(0.35);
    defer send.end();
    if (send.clicked()) {
        if (running and !can_send) s.interrupt() else if (can_send) {
            if (s.menu.open) assist.accept(s) else s.submit();
        }
        c.changed = true;
    }
    if (running and !can_send) {
        _ = c.leaf(.{ .width = .{ .px = 11 }, .height = .{ .px = 11 }, .radius = 3, .background = theme.background }, .none, null);
    } else ui.icon(c, "arrow.up", .{ .size = 13, .weight = .bold, .color = theme.background });
}

/// The pictures going with the next prompt, as thumbnails (a chip where
/// one can't be drawn); ✕ leaves one out.
fn pictures(c: *ui.Context, s: *Session) void {
    const items = s.attachments.items.items;
    if (items.len == 0 and s.attachments.problem == null) return;
    const r = ui.div(c).row().wFull().gap(8).itemsEnd().clip();
    defer r.end();
    for (items, 0..) |im, i| {
        ui.key(c, c.print("picture-{d}", .{i}));
        const d = ui.div(c).column().gap(4).p(3).rounded(10).bg(theme.background).border(theme.border);
        defer d.end();
        if (!ui.image(c, .{ .key = c.print("attach-{s}-{d}", .{ im.name, im.data.len }), .bytes = im.data, .max_width = 96, .max_height = 72, .radius = 7 })) {
            const chip_ = ui.div(c).row().gap(6).itemsCenter().px(6).py(4);
            defer chip_.end();
            ui.icon(c, "photo", .{ .size = 11, .color = theme.agent });
            ui.text(c, im.name[0..@min(im.name.len, 28)], .{ .size = 11.5 });
        }
        const row = ui.div(c).row().wFull().gap(4).itemsCenter().px(3);
        defer row.end();
        var buf: [24]u8 = undefined;
        ui.text(c, c.print("{s}", .{attach.size(&buf, im.data.len)}), .{ .size = 10.5, .color = theme.muted });
        ui.spacer(c);
        if (ui.button(c, "", .{ .variant = .ghost, .size = 8, .icon = "xmark" }).clicked) s.attachments.remove(i);
    }
    if (s.attachments.problem) |why| {
        ui.icon(c, "exclamationmark.triangle", .{ .size = 11, .color = theme.warning });
        ui.text(c, why, .{ .size = 11.5, .color = theme.warning });
    }
}

/// The agent and its model: one click to change either.
fn modelChip(c: *ui.Context, w: *Workspace, s: *Session) void {
    ui.key(c, "model-chip");
    const d = ui.div(c).row().gap(6).itemsCenter().px(10).py(5).roundedFull().hover(theme.text.alpha(0.06));
    defer d.end();
    if (d.clicked()) w.openModels();
    const dot: ui.Color = if (s.agent) |ag| switch (ag.status) {
        .off => theme.faint,
        .starting => theme.warning,
        .ready => theme.success,
        .working => theme.agent,
        .failed => theme.failure,
    } else theme.faint;
    _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = dot }, .none, null);
    ui.text(c, s.which.label(), .{ .size = 11.5, .weight = .semibold, .color = theme.text });
    ui.text(c, assist.modelLabel(s), .{ .size = 11.5, .mono = true, .color = theme.muted });
    ui.icon(c, "chevron.up.chevron.down", .{ .size = 9, .color = theme.muted });
}

/// Where Return sends what is typed; a click switches it.
fn modePill(c: *ui.Context, s: *Session) void {
    const agent = s.mode() == .agent;
    const color = if (agent) theme.agent else theme.accent;
    ui.key(c, "mode-pill");
    const d = ui.div(c).row().gap(5).itemsCenter().px(10).py(4).roundedFull().bg(color.alpha(0.12)).hover(color.alpha(0.2));
    defer d.end();
    const input_only = s.shell.busy() and !s.shell.remoteReady();
    if (d.clicked() and !input_only) s.toggleMode();
    if (agent) ui.icon(c, "sparkles", .{ .size = 11, .color = color }) else ui.text(c, "❯", .{ .size = 13, .weight = .bold, .color = color, .mono = true });
    ui.text(c, if (input_only) "input" else if (agent) "agent" else if (s.shell.remoteReady()) s.shell.remote.?.host else "shell", .{ .size = 11, .weight = .semibold, .color = color });
    const why: []const u8 = if (input_only or s.input.len == 0 and s.lock == null) "" else if (s.lock != null) "locked" else if (s.decidedByJev()) "jev" else "auto";
    if (why.len > 0) ui.text(c, why, .{ .size = 9.5, .color = color.alpha(0.7) });
}

fn menu(c: *ui.Context, s: *Session) void {
    const items = s.menu.items.items;
    if (items.len == 0) return;
    const box = ui.div(c).column().wFull().p(4).gap(0).bg(theme.background).rounded(8).border(theme.border).clip();
    defer box.end();
    // A window of rows around the selected one.
    const first = if (s.menu.selected >= menu_rows) s.menu.selected + 1 - menu_rows else 0;
    for (items[first..@min(items.len, first + menu_rows)], first..) |it, i| {
        ui.key(c, c.print("comp-{d}", .{i}));
        const selected = i == s.menu.selected;
        var row = ui.div(c).row().wFull().gap(8).itemsCenter().px(8).py(4).rounded(5);
        row = if (selected) row.bg(theme.block_selected) else row.hover(theme.block_hover);
        defer row.end();
        if (row.clicked()) {
            s.menu.selected = i;
            assist.accept(s);
        }
        ui.icon(c, kindIcon(it.kind), .{ .size = 10, .frame = 14, .color = if (selected) theme.accent else theme.muted });
        ui.text(c, it.word, .{ .size = 12.5, .mono = true, .color = if (selected) theme.text else theme.muted });
        if (it.detail.len > 0) {
            ui.spacer(c);
            ui.text(c, it.detail[0..@min(it.detail.len, 90)], .{ .size = 11.5, .color = theme.faint });
        }
    }
    if (items.len > menu_rows) ui.text(c, c.print("  {d} of {d}", .{ s.menu.selected + 1, items.len }), .{ .size = 10.5, .color = theme.faint });
}

fn kindIcon(k: complete.Kind) []const u8 {
    return switch (k) {
        .command => "terminal",
        .folder => "folder",
        .file => "doc",
        .git => "arrow.triangle.branch",
        .branch => "arrow.triangle.branch",
        .slash => "sparkles",
    };
}

fn chip(c: *ui.Context, icon: []const u8, label: []const u8, color: ui.Color) void {
    const d = ui.div(c).row().gap(5).itemsCenter().px(8).py(3).rounded(6).bg(color.alpha(0.1));
    defer d.end();
    ui.icon(c, icon, .{ .size = 10, .color = color });
    ui.text(c, label, .{ .size = 11.5, .mono = true, .color = color });
}
