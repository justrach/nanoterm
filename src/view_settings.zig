//! Settings (⌘,): the Codegraff account (one sign-in for nanoterm and
//! graff), the agents Harness ships (installed or not, the one new tabs
//! start with, an installer run in a new tab), appearance, text size,
//! updates, and about.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const agents = @import("agents.zig");
const agent_mod = @import("agent.zig");
const Workspace = @import("workspace.zig").Workspace;

pub fn card(c: *ui.Context, w: *Workspace) void {
    const panel = ui.div(c).column().w(@min(680, c.size.w - 40)).bg(theme.panel).rounded(14).border(theme.border).shadowLg().clip();
    defer panel.end();
    // Clicks inside stay inside.
    _ = panel.interaction();
    {
        const head = ui.div(c).row().wFull().itemsCenter().px(20).pt(16).pb(10);
        defer head.end();
        ui.text(c, "Settings", .{ .size = 17, .weight = .bold });
        ui.spacer(c);
        if (ui.button(c, "", .{ .variant = .ghost, .size = 11, .icon = "xmark" }).clicked) w.closeOverlay();
    }
    // As tall as it is, up to the window's room; then it scrolls.
    const body = ui.div(c).column().wFull().scrollY().maxH(c.size.h - 170).px(20).pb(20).gap(18);
    defer body.end();
    account(c, w);
    agentList(c, w);
    look(c, w);
    privacy(c, w);
    updates(c, w);
}

fn section(c: *ui.Context, title: []const u8) ui.Div {
    const col = ui.div(c).column().wFull().gap(8);
    ui.text(c, title, .{ .size = 12, .weight = .semibold, .color = theme.muted });
    return col;
}

fn box(c: *ui.Context) ui.Div {
    return ui.div(c).column().wFull().p(14).gap(10).bg(theme.background).rounded(10).border(theme.border);
}

pub fn account(c: *ui.Context, w: *Workspace) void {
    const s = section(c, "Codegraff");
    defer s.end();
    const b = box(c);
    defer b.end();
    const a = &w.shared.prefs.account;
    const r = ui.div(c).row().wFull().gap(12).itemsCenter();
    defer r.end();
    ui.icon(c, if (a.state == .signed_in) "person.crop.circle.fill.badge.checkmark" else "person.crop.circle", .{ .size = 26, .color = if (a.state == .signed_in) theme.success else theme.muted });
    {
        const t = ui.div(c).column().grow().gap(3);
        defer t.end();
        switch (a.state) {
            .signed_out => {
                ui.text(c, "Sign in with Codegraff", .{ .size = 14, .weight = .semibold });
                ui.text(c, "One sign-in for nanoterm and graff: Codegraff's models and credits, and Jev telling commands from questions.", .{ .size = 12, .color = theme.muted, .wrap = true });
            },
            .starting => ui.text(c, "Opening Codegraff…", .{ .size = 14, .weight = .semibold }),
            .waiting => {
                ui.text(c, "Approve the sign-in in your browser", .{ .size = 14, .weight = .semibold });
                if (a.code) |code| ui.text(c, c.print("Your code: {s}", .{code}), .{ .size = 12.5, .mono = true, .color = theme.muted });
            },
            .signed_in => {
                ui.text(c, a.email orelse "Signed in", .{ .size = 14, .weight = .semibold });
                if (a.credits_micro_usd) |cr| {
                    const dollars = @as(f64, @floatFromInt(cr)) / 1_000_000;
                    ui.text(c, c.print("${d:.2} in credits{s}{s}", .{ dollars, if (a.tier != null) " · " else "", a.tier orelse "" }), .{ .size = 12, .color = theme.muted });
                } else ui.text(c, "graff uses this sign-in too", .{ .size = 12, .color = theme.muted });
            },
        }
        if (a.failure) |why| ui.text(c, why, .{ .size = 12, .color = theme.failure, .wrap = true });
    }
    switch (a.state) {
        .signed_out => if (ui.button(c, "Sign in", .{ .variant = .primary, .size = 12.5 }).clicked) a.signIn(),
        .starting => {},
        .waiting => {
            if (ui.button(c, "Open again", .{ .size = 12 }).clicked) if (a.url) |u| a.open(u);
            if (ui.button(c, "Cancel", .{ .variant = .ghost, .size = 12 }).clicked) a.cancel();
        },
        .signed_in => if (ui.button(c, "Sign out", .{ .size = 12 }).clicked) a.signOut(),
    }
}

pub fn agentList(c: *ui.Context, w: *Workspace) void {
    const s = section(c, "Agents");
    defer s.end();
    const b = box(c);
    const prefs = &w.shared.prefs;
    {
        // Off: a terminal and nothing else.
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        const t = ui.div(c).column().grow().gap(2);
        {
            defer t.end();
            ui.text(c, "Coding agents", .{ .size = 13 });
            ui.text(c, if (prefs.agents) "Questions go to your agent; commands run." else "Off: a terminal and nothing else. Everything typed runs; nothing is sent to an agent.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
        }
        var on = prefs.agents;
        if (ui.toggle(c, "", &on)) prefs.setAgents(on);
    }
    if (!prefs.agents) return b.end();
    for (agents.all, 0..) |info, i| {
        ui.key(c, c.print("agent-{d}", .{i}));
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = theme.border }, .none, null);
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        const have = prefs.installed.get(info.which);
        _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = if (have) theme.success else theme.faint }, .none, null);
        {
            const f = ui.div(c).w(22).h(22).center();
            defer f.end();
            _ = ui.image(c, .{ .key = c.print("agent-mark-{s}", .{@tagName(info.which)}), .bytes = @import("marks.zig").agent(info.which), .max_width = 20, .max_height = 20, .radius = 0, .tint = if (have) theme.text else theme.faint });
        }
        {
            const t = ui.div(c).column().grow().gap(2);
            defer t.end();
            ui.text(c, info.which.label(), .{ .size = 13.5, .weight = .semibold });
            ui.text(c, if (have) info.blurb else c.print("Not installed · {s}", .{info.blurb}), .{ .size = 11.5, .color = theme.muted, .wrap = true });
        }
        if (!have) {
            if (ui.button(c, "Install", .{ .size = 12, .icon = "arrow.down.circle" }).clicked) runInTab(w, info.install);
            continue;
        }
        if (info.login.len > 0 and info.which != .graff) {
            if (ui.button(c, "Sign in", .{ .variant = .ghost, .size = 12 }).clicked) runInTab(w, info.login);
        }
        if (prefs.agent == info.which) {
            const d = ui.div(c).row().gap(5).itemsCenter().px(10).py(4).rounded(7).bg(theme.agent.alpha(0.12));
            defer d.end();
            ui.icon(c, "checkmark", .{ .size = 10, .weight = .bold, .color = theme.agent });
            ui.text(c, "Default", .{ .size = 12, .color = theme.agent });
        } else if (ui.button(c, "Make default", .{ .variant = .ghost, .size = 12 }).clicked) {
            prefs.setAgent(info.which);
            w.focused().choose(info.which);
        }
    }
    ui.text(c, "New tabs start with the default agent; ⌘⇧M switches the one a pane uses.", .{ .size = 11.5, .color = theme.faint });
    b.end();
    // graff's own sign-ins, as Harness lists them.
    if (prefs.installed.get(.graff)) @import("view_signins.zig").section(c, w, box);
}

/// Runs `command` in a new tab (an installer, a sign-in), and closes Settings.
pub fn runInTab(w: *Workspace, command: []const u8) void {
    const s = w.newTab(w.shared.home) catch return;
    s.run(command);
    w.closeOverlay();
}

fn look(c: *ui.Context, w: *Workspace) void {
    const s = section(c, "Appearance");
    defer s.end();
    const b = box(c);
    defer b.end();
    {
        const r = ui.div(c).row().wFull().itemsCenter();
        defer r.end();
        ui.text(c, "Theme", .{ .size = 13 });
        ui.spacer(c);
        const names = [_][]const u8{ "System", "Light", "Dark" };
        const order = [_]@TypeOf(w.shared.appearance){ .system, .light, .dark };
        var picked: usize = std.mem.indexOfScalar(@TypeOf(w.shared.appearance), &order, w.shared.appearance) orelse 0;
        if (ui.segmented(c, &names, &picked)) w.shared.setAppearance(order[picked]);
    }
    {
        const r = ui.div(c).row().wFull().itemsCenter();
        defer r.end();
        ui.text(c, "Keys in the input", .{ .size = 13 });
        ui.spacer(c);
        const names = [_][]const u8{ "Standard", "Emacs", "Vim" };
        const order = [_]ui.Keymap{ .system, .emacs, .vim };
        var picked: usize = std.mem.indexOfScalar(ui.Keymap, &order, w.shared.prefs.keys) orelse 0;
        if (ui.segmented(c, &names, &picked)) w.shared.prefs.setKeys(order[picked]);
    }
    {
        const r = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer r.end();
        ui.text(c, "Text size", .{ .size = 13 });
        ui.spacer(c);
        if (ui.button(c, "", .{ .size = 11, .icon = "minus" }).clicked) w.zoomBy(-0.1);
        ui.text(c, c.print("{d:.0}%", .{w.zoom * 100}), .{ .size = 12.5, .mono = true, .color = theme.muted });
        if (ui.button(c, "", .{ .size = 11, .icon = "plus" }).clicked) w.zoomBy(0.1);
        if (ui.button(c, "Reset", .{ .variant = .ghost, .size = 12 }).clicked) w.zoom = 1;
    }
}

/// Anonymous usage analytics: shared or not, under the privacy policy.
fn privacy(c: *ui.Context, w: *Workspace) void {
    const s = section(c, "Privacy");
    defer s.end();
    const b = box(c);
    defer b.end();
    const an = @import("analytics.zig");
    {
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        const t = ui.div(c).column().grow().gap(2);
        {
            defer t.end();
            ui.text(c, "Share anonymous usage", .{ .size = 13 });
            ui.text(c, "Which features you use, the app's version and your OS. Never your commands, prompts, files or output.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
        }
        var on = w.shared.prefs.analytics == .on;
        if (ui.toggle(c, "", &on)) w.shared.prefs.setAnalytics(if (on) .on else .off, w.shared.io);
    }
    // The id events carry, to ask for them to be deleted.
    const id = &w.shared.prefs.install_id;
    if (!std.mem.allEqual(u8, id, '0')) ui.text(c, c.print("Install ID: {s}", .{id}), .{ .size = 11.5, .mono = true, .color = theme.muted });
    const links = ui.div(c).row().gap(14);
    defer links.end();
    if (ui.button(c, "Privacy Policy", .{ .variant = .ghost, .size = 11.5, .icon = "hand.raised" }).clicked) _ = nanoui.shell.openUrl(an.privacy_url);
    if (ui.button(c, "Terms", .{ .variant = .ghost, .size = 11.5, .icon = "doc.text" }).clicked) _ = nanoui.shell.openUrl(an.terms_url);
}

fn updates(c: *ui.Context, w: *Workspace) void {
    const s = section(c, "Updates");
    defer s.end();
    const b = box(c);
    defer b.end();
    const r = ui.div(c).row().wFull().gap(10).itemsCenter();
    defer r.end();
    const u = w.updater orelse {
        ui.text(c, "This build doesn't update itself (it isn't an installed app).", .{ .size = 12.5, .color = theme.muted });
        return;
    };
    {
        const t = ui.div(c).column().grow().gap(2);
        defer t.end();
        ui.text(c, c.print("nanoterm {s}", .{if (u.current.len > 0) u.current else "dev"}), .{ .size = 13.5, .weight = .semibold });
        const note: []const u8 = if (u.ready()) |v| c.print("Version {s} is ready to install.", .{v}) else switch (u.phase.load(.acquire)) {
            .busy => "Checking for updates…",
            .installed => "Updated: it runs from the next launch.",
            else => "Checks for updates every few hours, and installs them when you quit.",
        };
        ui.text(c, note, .{ .size = 12, .color = theme.muted, .wrap = true });
    }
    if (u.ready() != null) {
        if (ui.button(c, "Restart to update", .{ .variant = .primary, .size = 12 }).clicked) if (u.restart()) w.nanoapp.quit();
    } else if (ui.button(c, "Check now", .{ .size = 12 }).clicked) u.checkNow();
}
