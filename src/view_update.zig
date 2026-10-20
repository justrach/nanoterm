//! A newer nanoterm, downloaded and checked: a card of Liquid Glass floats
//! in at the window's top right asking to restart into it. "Later" puts it
//! away for that version (the title bar keeps a small button), and
//! quitting installs it anyway. A newer graff, already in place, gets a
//! card of its own, Harness's "Codegraff engine updated", with its lines.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const Workspace = @import("workspace.zig").Workspace;

/// Whether the card is up (so the title bar's button waits).
pub fn showing(w: *const Workspace) bool {
    const u = w.updater orelse return false;
    const v = u.ready() orelse return false;
    return !std.mem.eql(u8, w.update_later[0..w.update_later_len], v);
}

pub fn card(c: *ui.Context, w: *Workspace, top: f32) void {
    appCard(c, w, top);
    graffCard(c, if (showing(w)) top + 112 else top);
}

fn appCard(c: *ui.Context, w: *Workspace, top: f32) void {
    // Animated every frame (at 0 while hidden), so it slides in from the
    // right edge when an update comes.
    const t = c.animate(std.hash.Wyhash.hash(0, "update-card"), 0, if (showing(w)) 1 else 0, 7);
    if (!showing(w)) return;
    const u = w.updater.?;
    const version = u.ready().?;
    const width: f32 = 330;
    ui.key(c, "update-card");
    const d = ui.div(c).absolute().offset(c.size.w - width - 16 + (1 - t) * (width + 24), top + 10).w(width).column().gap(10).p(14).rounded(16).glass(.{}).border(theme.border.alpha(0.6))
        .shadow(.{ .color = .{ .a = if (theme.dark) 0.35 else 0.12 }, .blur = 22, .y = 8 }).opacity(t);
    defer d.end();
    _ = d.interaction();
    {
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        ui.icon(c, "arrow.down.circle.fill", .{ .size = 22, .color = theme.accent });
        const col = ui.div(c).column().grow().gap(2);
        defer col.end();
        ui.text(c, c.print("nanoterm {s} is ready", .{version}), .{ .size = 13.5, .weight = .semibold });
        ui.text(c, "Restart now, or it installs when you quit.", .{ .size = 11.5, .color = theme.muted });
    }
    const r = ui.div(c).row().wFull().gap(8).justifyEnd();
    defer r.end();
    if (ui.button(c, "Later", .{ .variant = .ghost, .size = 12 }).clicked) {
        const n = @min(version.len, w.update_later.len);
        @memcpy(w.update_later[0..n], version[0..n]);
        w.update_later_len = n;
    }
    if (ui.button(c, "Restart now", .{ .variant = .primary, .size = 12 }).clicked) if (u.restart()) w.nanoapp.quit();
}

/// Release lines shown on the graff card; the rest are in the notes.
const max_lines = 4;

fn graffCard(c: *ui.Context, top: f32) void {
    const u = graff_update.global orelse return;
    const t = c.animate(std.hash.Wyhash.hash(0, "graff-card"), 0, if (u.notice != null) 1 else 0, 7);
    const n = u.notice orelse return;
    const width: f32 = 340;
    ui.key(c, "graff-card");
    const d = ui.div(c).absolute().offset(c.size.w - width - 16 + (1 - t) * (width + 24), top + 10).w(width).column().gap(10).p(14).rounded(16).glass(.{}).border(theme.border.alpha(0.6))
        .shadow(.{ .color = .{ .a = if (theme.dark) 0.35 else 0.12 }, .blur = 22, .y = 8 }).opacity(t);
    defer d.end();
    _ = d.interaction();
    {
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        const mark = ui.div(c).w(30).h(30).rounded(8).center().bg(theme.accent.alpha(0.14));
        {
            defer mark.end();
            ui.icon(c, "sparkle", .{ .size = 15, .color = theme.accent });
        }
        const col = ui.div(c).column().grow().gap(3);
        defer col.end();
        ui.text(c, "Codegraff engine updated", .{ .size = 13, .weight = .semibold });
        const vs = ui.div(c).row().gap(5).itemsCenter();
        defer vs.end();
        if (n.from.len > 0) {
            ui.text(c, c.print("v{s}", .{n.from}), .{ .size = 11, .color = theme.muted });
            ui.icon(c, "arrow.right", .{ .size = 10, .color = theme.faint });
        }
        const chip = ui.div(c).px(6).py(1).rounded(5).bg(theme.accent.alpha(0.14));
        defer chip.end();
        ui.text(c, c.print("v{s}", .{n.to}), .{ .size = 11, .weight = .semibold, .color = theme.accent });
    }
    if (n.lines.len > 0) {
        const rule = ui.div(c).wFull().h(1).bg(theme.border);
        rule.end();
        const body = ui.div(c).column().wFull().gap(5);
        defer body.end();
        ui.text(c, "WHAT'S NEW", .{ .size = 10.5, .weight = .semibold, .color = theme.faint });
        for (n.lines[0..@min(n.lines.len, max_lines)], 0..) |line, i| {
            ui.key(c, c.print("graff-line-{d}", .{i}));
            const r = ui.div(c).row().wFull().gap(8).itemsStart();
            defer r.end();
            const at = ui.div(c).pt(6);
            {
                defer at.end();
                const dot = ui.div(c).w(5).h(5).roundedFull().bg(theme.accent);
                dot.end();
            }
            const words = ui.div(c).column().grow();
            defer words.end();
            ui.text(c, line, .{ .size = 12, .color = theme.text, .wrap = true });
        }
        if (n.lines.len > max_lines) ui.text(c, c.print("+{d} more in the release notes", .{n.lines.len - max_lines}), .{ .size = 11, .color = theme.muted });
    }
    const note = if (n.from.len > 0) c.print("New chats use it. Open chats stay on v{s} until you start a new one.", .{n.from}) else "New chats use it.";
    ui.text(c, note, .{ .size = 11, .color = theme.muted, .wrap = true });
    const r = ui.div(c).row().wFull().gap(8).justifyEnd();
    defer r.end();
    if (ui.button(c, "Release notes", .{ .variant = .ghost, .size = 12 }).clicked) {
        _ = nanoui.shell.openUrl(c.print("https://github.com/justrach/codegraff/releases/tag/v{s}", .{n.to}));
    }
    if (ui.button(c, "Got it", .{ .variant = .primary, .size = 12 }).clicked) u.dismiss();
}

const graff_update = @import("graff_update.zig");
