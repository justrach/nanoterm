//! Settings' "graff providers", as Harness's accounts screen has them:
//! ChatGPT, xAI, Kimi and Z.AI, each with whether graff is signed in to it
//! (graff_logins.zig reads graff's own credential files), Sign in (Continue
//! with ChatGPT; Sign in again once signed in) and a trash button to sign
//! out. A sign-in under way shows graff's code to confirm (xAI, Kimi) and the
//! page it opened; a failed one, graff's own reason.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const marks = @import("marks.zig");
const gl = @import("graff_logins.zig");
const agents = @import("agents.zig");
const proc = @import("proc.zig");
const Workspace = @import("workspace.zig").Workspace;

/// graff on PATH or where its installer puts it.
fn graffPath(c: *ui.Context, w: *Workspace) ?[]const u8 {
    const path = agents.searchPath(c.alloc(), w.shared.env.get("PATH") orelse "", w.shared.home);
    return proc.which(c.alloc(), w.shared.io, path, "graff");
}

/// The section, its rows in a `card` like Settings' others.
pub fn section(c: *ui.Context, w: *Workspace, comptime card: fn (*ui.Context) ui.Div) void {
    const logins = &w.shared.prefs.graff;
    {
        const h = ui.div(c).row().gap(8).itemsCenter().pt(8);
        defer h.end();
        _ = ui.image(c, .{ .key = "graff-providers-mark", .bytes = marks.agent(.graff), .max_width = 16, .max_height = 16, .radius = 0, .tint = theme.muted });
        ui.text(c, "graff providers", .{ .size = 12, .weight = .semibold, .color = theme.muted });
    }
    ui.text(c, "Bring your own sign-ins: graff runs on your plan, no credits needed.", .{ .size = 11.5, .color = theme.faint, .wrap = true });
    const b = card(c);
    defer b.end();
    for (gl.providers, 0..) |p, i| {
        ui.key(c, c.print("graff-login-{s}", .{p.id}));
        if (i > 0) _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = theme.border }, .none, null);
        const st = gl.status(c.alloc(), w.shared.io, logins.home, p.id);
        const flow: ?*gl.Flow = if (logins.flow) |f| (if (std.mem.eql(u8, f.id, p.id)) f else null) else null;
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        {
            const m = ui.div(c).w(22).h(22).center();
            defer m.end();
            if (marks.of(p.lab)) |png| _ = ui.image(c, .{ .key = c.print("graff-login-mark-{s}", .{p.id}), .bytes = png, .max_width = 18, .max_height = 18, .radius = 0, .tint = if (st.signed_in) theme.text else theme.faint });
        }
        {
            const t = ui.div(c).column().grow().gap(2);
            defer t.end();
            ui.text(c, p.name, .{ .size = 13.5, .weight = .semibold });
            statusLine(c, logins, p, st, flow);
        }
        if (flow) |f| {
            if (f.signing_out) continue;
            if (gl.scanUrl(f.output.items)) |url| if (ui.button(c, "Open page", .{ .variant = .ghost, .size = 12 }).clicked) {
                _ = nanoui.shell.openUrl(url);
            };
            if (ui.button(c, "Cancel", .{ .variant = .ghost, .size = 12 }).clicked) logins.cancel();
            continue;
        }
        if (st.signed_in and ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = "trash" }).clicked) {
            logins.signOut(graffPath(c, w), w.shared.env_list, p.id);
        }
        const label = if (std.mem.eql(u8, p.id, "chatgpt-new")) "Continue with ChatGPT" else if (st.signed_in) "Sign in again" else "Sign in";
        if (ui.button(c, label, .{ .variant = .primary, .size = 12 }).clicked) {
            if (graffPath(c, w)) |g| logins.start(g, w.shared.env_list, p.id) catch {};
        }
    }
}

fn statusLine(c: *ui.Context, logins: *const gl.Logins, p: gl.Provider, st: gl.Status, flow: ?*gl.Flow) void {
    const small: ui.TextStyle = .{ .size = 11.5, .color = theme.muted, .wrap = true };
    if (flow) |f| {
        if (f.signing_out) return ui.text(c, "Signing out…", small);
        const row = ui.div(c).row().gap(8).itemsCenter();
        defer row.end();
        ui.text(c, if (gl.scanUrl(f.output.items) == null) "Starting the sign-in…" else "Finish in your browser", .{ .size = 11.5, .color = theme.muted });
        if (gl.scanCode(f.output.items)) |code| {
            const chip = ui.div(c).px(7).py(2).rounded(5).bg(theme.accent.alpha(0.14));
            defer chip.end();
            ui.text(c, c.print("Code {s}", .{code}), .{ .size = 11.5, .mono = true, .weight = .semibold, .color = theme.accent });
        }
        return;
    }
    if (std.mem.eql(u8, logins.failed_id, p.id) and logins.failed.items.len > 0) {
        return ui.text(c, logins.failed.items, .{ .size = 11.5, .color = theme.failure, .wrap = true });
    }
    if (st.plan_off) return ui.text(c, gl.plan_off_message, small);
    if (st.signed_in) {
        if (st.account.len > 0) return ui.text(c, c.print("Signed in as {s}", .{st.account}), small);
        return ui.text(c, "Signed in on this device", small);
    }
    ui.text(c, "Not signed in", small);
}
