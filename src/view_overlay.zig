//! Panels over the panes: the command palette (⌘P) and the agent and
//! model picker (⌘⇧M, or the model chip). Both are a search field over a
//! list: type to filter, ↑↓ to choose, ↩ to take, esc or a click outside
//! to close.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const palette = @import("palette.zig");
const assist = @import("assist.zig");
const agent_mod = @import("agent.zig");
const Workspace = @import("workspace.zig").Workspace;
const Session = @import("session.zig").Session;

/// Rows shown at once.
const rows = 8;

pub fn overlay(c: *ui.Context, w: *Workspace) void {
    if (w.overlay == .none) return;
    const scrim = ui.div(c).absolute().sizeFull().column().itemsCenter().bg(.{ .a = if (theme.dark) 0.4 else 0.16 });
    c.node(scrim.index).style.padding.top = 64;
    defer scrim.end();
    if (scrim.clicked()) return w.closeOverlay();
    if (w.overlay == .palette) return @import("view_palette.zig").card(c, w);
    if (w.overlay == .settings) return @import("view_settings.zig").card(c, w);
    const card = ui.div(c).column().w(@min(620, c.size.w - 40)).p(8).gap(6).bg(theme.panel).rounded(12).border(theme.border).shadowLg();
    defer card.end();
    // Clicks inside the card stay in it.
    _ = card.interaction();
    switch (w.overlay) {
        .palette => {},
        .models => modelsView(c, w),
        .none, .settings => {},
    }
}

/// The search field; true when ↩ was pressed.
fn search(c: *ui.Context, w: *Workspace, placeholder: []const u8) bool {
    const id = c.peekId(null);
    c.focus = id;
    const r = ui.textField(c, &w.query, .{ .placeholder = placeholder, .width = .fill, .size = 14 });
    if (r.changed) w.pick = 0;
    return r.submitted;
}

/// The first row shown, so that the picked one is in view.
fn firstRow(pick: usize) usize {
    return if (pick >= rows) pick + 1 - rows else 0;
}

const Row = struct {
    icon: []const u8,
    title: []const u8,
    detail: []const u8 = "",
    right: []const u8 = "",
    current: bool = false,
    mono: bool = false,
    keys: bool = false,
    /// A maker's mark (PNG) in the icon's place, and its name (its key).
    mark: ?[]const u8 = null,
    mark_key: []const u8 = "",
};

/// A list row; true when clicked.
fn row(c: *ui.Context, w: *Workspace, i: usize, r: Row) bool {
    ui.key(c, c.print("row-{d}", .{i}));
    const picked = i == w.pick;
    var d = ui.div(c).row().wFull().gap(10).itemsCenter().px(10).py(6).rounded(7);
    d = if (picked) d.bg(theme.block_selected) else d.hover(theme.block_hover);
    defer d.end();
    const clicked = d.clicked();
    if (d.hovered()) w.pick = i;
    const tone = if (r.current) theme.success else if (picked) theme.accent else theme.muted;
    if (r.mark) |png| {
        const f = ui.div(c).w(16).h(16).center();
        defer f.end();
        _ = ui.image(c, .{ .key = r.mark_key, .bytes = png, .max_width = 15, .max_height = 15, .radius = 0, .tint = tone });
    } else ui.icon(c, r.icon, .{ .size = 11, .frame = 16, .color = tone });
    {
        const col = ui.div(c).column().gap(1).grow().clip();
        defer col.end();
        ui.text(c, r.title, .{ .size = 13, .mono = r.mono, .color = if (picked) theme.text else theme.text.alpha(0.85) });
        if (r.detail.len > 0) ui.text(c, r.detail, .{ .size = 11, .color = theme.faint });
    }
    if (r.right.len > 0) {
        if (r.keys) ui.kbd(c, r.right) else ui.text(c, r.right, .{ .size = 11.5, .color = theme.muted });
    }
    if (r.current and r.mark != null) ui.icon(c, "checkmark", .{ .size = 11, .weight = .bold, .color = theme.success });
    return clicked;
}

fn modelsView(c: *ui.Context, w: *Workspace) void {
    const s = w.focused();
    {
        const r = ui.div(c).row().wFull().gap(10).itemsCenter().px(4).py(2);
        defer r.end();
        ui.text(c, "Agent", .{ .size = 12, .weight = .semibold, .color = theme.muted });
        // The agents installed (and the one in use), as Settings found them.
        var shown: [std.enums.values(agent_mod.Which).len]agent_mod.Which = undefined;
        var names: [shown.len][]const u8 = undefined;
        var n: usize = 0;
        var selected: usize = 0;
        for (std.enums.values(agent_mod.Which)) |which| {
            if (which != s.which and which != .graff and which != .claude and !w.shared.prefs.installed.get(which)) continue;
            if (which == s.which) selected = n;
            shown[n] = which;
            names[n] = which.label();
            n += 1;
        }
        if (ui.segmented(c, names[0..n], &selected)) {
            s.choose(shown[selected]);
            assist.prepareModels(s);
            w.pick = 0;
        }
        ui.spacer(c);
        status(c, s);
    }
    options(c, s);
    const enter = search(c, w, "Search models…");
    // graff's session, once up, lists its models with makers and how each
    // is paid for: asked once.
    const cat = &s.shared.catalog;
    if (s.which == .graff and cat.acp == .none) if (s.agent) |ag| if (ag.session != null) {
        cat.acp = .asked;
        ag.client.request("graff/models", .{}, cat, @import("catalog.zig").Catalog.onAcp) catch {
            cat.acp = .answered;
        };
    };
    const Choice = struct { value: []const u8, row: Row, section: []const u8 = "" };
    var list: std.ArrayList(Choice) = .empty;
    const q = w.query.text();
    const current = assist.modelLabel(s);
    if (s.agent) |ag| if (ag.config.find("model")) |o| {
        for (o.choices) |ch| if (palette.score(ch.name, q) != null or palette.score(ch.value, q) != null)
            list.append(c.alloc(), .{ .value = ch.value, .row = .{ .icon = if (std.mem.eql(u8, ch.value, o.current)) "checkmark.circle.fill" else "cpu", .title = ch.name, .detail = ch.description, .current = std.mem.eql(u8, ch.value, o.current) } }) catch {};
    };
    if (list.items.len == 0 and s.which == .graff) {
        const CatMod = @import("catalog.zig");
        const marks = @import("marks.zig");
        for (cat.models.items) |m| {
            const name = c.print("{s} {s}", .{ m.provider, m.name });
            if (palette.score(name, q) == null) continue;
            const is_current = if (cat.acp == .answered) m.current else std.mem.eql(u8, m.name, current);
            const mk = marks.maker(m.maker, m.provider, m.name);
            const note = CatMod.costNote(m.cost);
            list.append(c.alloc(), .{
                .value = m.name,
                .section = if (note.len > 0) c.print("{s} · {s}", .{ CatMod.providerName(m.provider), note }) else CatMod.providerName(m.provider),
                .row = .{ .icon = if (is_current) "checkmark.circle.fill" else "cpu", .title = m.name, .detail = if (cat.acp == .answered) m.detail else c.print("{s} · {s}", .{ m.provider, m.detail }), .current = is_current, .mono = true, .mark = marks.of(mk), .mark_key = c.print("mark-{s}", .{mk}) },
            }) catch {};
            if (list.items.len >= 300) break;
        }
        if (cat.state == .loading) ui.text(c, "Loading graff's models…", .{ .size = 12, .color = theme.muted });
        if (cat.state == .failed) ui.text(c, "graff did not list its models: type a name and press ↩", .{ .size = 12, .color = theme.warning });
    }
    const items = list.items;
    w.pick = @min(w.pick, items.len -| 1);
    var chosen: ?[]const u8 = if (enter) (if (items.len > 0) items[w.pick].value else if (q.len > 0) q else null) else null;
    const first = firstRow(w.pick);
    for (items[first..@min(items.len, first + rows)], first..) |ch, i| {
        // A provider's title where its models start: "Codex · your plan".
        if (ch.section.len > 0 and (i == first or !std.mem.eql(u8, ch.section, items[i - 1].section))) {
            ui.key(c, c.print("section-{d}", .{i}));
            const h = ui.div(c).row().wFull().px(10).pt(if (i == first) 2 else 8).pb(2);
            defer h.end();
            ui.text(c, ch.section, .{ .size = 11, .weight = .semibold, .color = theme.muted });
        }
        if (row(c, w, i, ch.row)) chosen = ch.value;
    }
    if (items.len == 0 and s.agent != null and s.agent.?.status == .starting) ui.text(c, c.print("Starting {s} to see its models…", .{s.which.label()}), .{ .size = 12, .color = theme.muted });
    const value = chosen orelse return;
    // The name outlives the frame: it is copied before the overlay goes.
    assist.chooseModel(s, value);
    w.closeOverlay();
    c.changed = true;
}

fn status(c: *ui.Context, s: *Session) void {
    const ag = s.agent orelse return;
    const text: []const u8 = switch (ag.status) {
        .off => "",
        .starting => "starting…",
        .ready => "ready",
        .working => "working…",
        .failed => ag.error_text orelse "failed",
    };
    ui.text(c, text[0..@min(text.len, 60)], .{ .size = 11.5, .color = if (ag.status == .failed) theme.failure else theme.muted });
}

/// The agent's other choices (mode, thought level), one row each.
fn options(c: *ui.Context, s: *Session) void {
    const ag = s.agent orelse return;
    for (ag.config.options.items) |*o| {
        if (std.mem.eql(u8, o.category, "model") or o.choices.len < 2 or o.choices.len > 7) continue;
        const r = ui.div(c).row().wFull().gap(10).itemsCenter().px(4).py(2);
        defer r.end();
        ui.text(c, o.name, .{ .size = 12, .weight = .semibold, .color = theme.muted });
        const names = c.alloc().alloc([]const u8, o.choices.len) catch return;
        var selected: usize = 0;
        for (o.choices, 0..) |ch, i| {
            names[i] = ch.name;
            if (std.mem.eql(u8, ch.value, o.current)) selected = i;
        }
        if (ui.segmented(c, names, &selected)) {
            const id = c.alloc().dupe(u8, o.id) catch return;
            const value = c.alloc().dupe(u8, o.choices[selected].value) catch return;
            ag.setOption(id, value);
        }
    }
}
