//! An SSH session in the timeline: in the block of `ssh host`, a bar that
//! sets the remote shell up (a block per command, its folder, the agent
//! working there), then says so.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const blocks = @import("blocks.zig");
const App = @import("session.zig").Session;

/// The bar of the SSH session `b` is, if it is one.
pub fn bar(c: *ui.Context, app: *App, b: *blocks.Block) void {
    const r = app.shell.remote orelse return;
    if (r.session != b) return;
    ui.key(c, "remote-bar");
    const d = ui.div(c).row().wFull().gap(10).itemsCenter().px(12).py(9).rounded(10).bg(theme.accent.alpha(0.08)).border(theme.accent.alpha(0.3));
    defer d.end();
    ui.icon(c, "globe", .{ .size = 12, .color = theme.accent });
    if (r.active) {
        const where = if (r.cwd.items.len > 0) r.cwd.items else "~";
        ui.text(c, c.print("On {s} · {s}", .{ r.host, where }), .{ .size = 12.5, .weight = .semibold, .mono = true });
        ui.text(c, c.print("each command is a block · {s} works here too", .{app.which.label()}), .{ .size = 12, .color = theme.muted });
        return;
    }
    {
        const t = ui.div(c).column().grow().gap(2);
        defer t.end();
        ui.text(c, c.print("Signed in to {s}?", .{r.host}), .{ .size = 12.5, .weight = .semibold });
        ui.text(c, c.print("Set nanoterm up here, for this session: a block per command, the remote folder, and {s} working on {s}.", .{ app.which.label(), r.host }), .{ .size = 12, .color = theme.muted, .wrap = true });
    }
    if (ui.button(c, "Set up", .{ .variant = .primary, .size = 12.5, .icon = "wand.and.stars" }).clicked) {
        app.shell.setUpRemote();
        c.changed = true;
    }
}
