//! A newer nanoterm, downloaded and checked: a card of Liquid Glass floats
//! in at the window's top right asking to restart into it. "Later" puts it
//! away for that version (the title bar keeps a small button), and
//! quitting installs it anyway.
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
