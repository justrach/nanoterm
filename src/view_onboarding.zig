//! The first launch: three choices before anything else. How to start
//! (sign in with Codegraff, where new accounts get $1 of credits; connect
//! your own agents; or just the terminal), the input's keys (standard,
//! Emacs, Vim), and whether to share anonymous usage analytics, under
//! Standard Harness's privacy policy. Each can be changed in Settings.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const analytics = @import("analytics.zig");
const settings_view = @import("view_settings.zig");
const Workspace = @import("workspace.zig").Workspace;

pub const Step = enum { start, agents, keys, analytics };

pub fn card(c: *ui.Context, w: *Workspace) void {
    const panel = ui.div(c).column().w(@min(620, c.size.w - 40)).p(28).gap(18).bg(theme.panel).rounded(18).border(theme.border).shadowLg();
    defer panel.end();
    _ = panel.interaction();
    dots(c, w.onboarding);
    switch (w.onboarding) {
        .start => start(c, w),
        .agents => agentsStep(c, w),
        .keys => keysStep(c, w),
        .analytics => analyticsStep(c, w),
    }
}

/// Where in the three steps it is.
fn dots(c: *ui.Context, step: Step) void {
    const at: usize = switch (step) {
        .start, .agents => 0,
        .keys => 1,
        .analytics => 2,
    };
    const r = ui.div(c).row().gap(6);
    defer r.end();
    for (0..3) |i| _ = c.leaf(.{ .width = .{ .px = if (i == at) 18 else 6 }, .height = .{ .px = 6 }, .radius = 3, .background = if (i <= at) theme.accent else theme.border }, .none, null);
}

fn title(c: *ui.Context, big: []const u8, small: []const u8) void {
    const t = ui.div(c).column().gap(6);
    defer t.end();
    ui.text(c, big, .{ .size = 22, .weight = .bold });
    ui.text(c, small, .{ .size = 13.5, .color = theme.muted, .wrap = true });
}

/// A choice: a mark, a title and what it means; true when clicked.
fn choice(c: *ui.Context, key: []const u8, icon: []const u8, head: []const u8, body: []const u8, primary: bool, picked: bool) bool {
    ui.key(c, key);
    var d = ui.div(c).row().wFull().gap(14).itemsCenter().p(14).rounded(12).border(if (picked) theme.accent else theme.border).control();
    d = if (primary) d.bg(theme.accent.alpha(0.08)).hover(theme.accent.alpha(0.14)) else d.bg(theme.background).hover(theme.block_hover);
    defer d.end();
    ui.icon(c, icon, .{ .size = 20, .frame = 28, .color = if (primary or picked) theme.accent else theme.muted });
    {
        const t = ui.div(c).column().grow().gap(3);
        defer t.end();
        ui.text(c, head, .{ .size = 14, .weight = .semibold });
        ui.text(c, body, .{ .size = 12, .color = theme.muted, .wrap = true });
    }
    if (picked) ui.icon(c, "checkmark.circle.fill", .{ .size = 16, .color = theme.accent });
    return d.clicked();
}

fn footer(c: *ui.Context) ui.Div {
    return ui.div(c).row().wFull().gap(8).itemsCenter().justifyEnd();
}

fn start(c: *ui.Context, w: *Workspace) void {
    title(c, "Welcome to nanoterm", "Commands and questions in one input: it runs commands in blocks, and hands questions to a coding agent. How would you like to start?");
    const a = &w.shared.prefs.account;
    switch (a.state) {
        .signed_out => if (choice(c, "ob-signin", "sparkles", "Sign in with Codegraff", "New accounts start with $1 in free credits. One sign-in for graff's models, Codegraff's credits, and Jev telling commands from questions.", true, false)) a.signIn(),
        .starting, .waiting => {
            const b = ui.div(c).column().wFull().gap(8).p(14).rounded(12).bg(theme.accent.alpha(0.08)).border(theme.accent);
            defer b.end();
            ui.text(c, "Approve the sign-in in your browser", .{ .size = 14, .weight = .semibold });
            if (a.code) |code| ui.text(c, c.print("Your code: {s}", .{code}), .{ .size = 13, .mono = true, .color = theme.muted });
            const r = ui.div(c).row().gap(8);
            defer r.end();
            if (ui.button(c, "Open again", .{ .size = 12 }).clicked) if (a.url) |u| a.open(u);
            if (ui.button(c, "Cancel", .{ .variant = .ghost, .size = 12 }).clicked) a.cancel();
        },
        .signed_in => _ = choice(c, "ob-signed", "person.crop.circle.fill.badge.checkmark", c.print("Signed in{s}{s}", .{ if (a.email != null) " as " else "", a.email orelse "" }), "graff and Jev use this sign-in too.", false, true),
    }
    if (a.failure) |why| ui.text(c, why, .{ .size = 12, .color = theme.failure, .wrap = true });
    if (choice(c, "ob-agents", "cpu", "Connect your own agents", "Claude Code, Codex, opencode, Grok and others, with your own subscriptions.", false, false)) {
        w.shared.prefs.refresh(w.shared.env);
        w.onboarding = .agents;
    }
    if (choice(c, "ob-plain", "terminal", "Just the terminal", "Use nanoterm without an agent. Set one up any time in Settings (⌘,).", false, false)) w.onboarding = .keys;
    if (a.state == .signed_in) {
        const f = footer(c);
        defer f.end();
        if (ui.button(c, "Continue", .{ .variant = .primary, .size = 13 }).clicked) w.onboarding = .keys;
    }
}

fn agentsStep(c: *ui.Context, w: *Workspace) void {
    title(c, "Connect your agents", "Install the ones you use, or sign in to them. New tabs start with the default.");
    settings_view.agentList(c, w);
    const f = footer(c);
    defer f.end();
    if (ui.button(c, "Back", .{ .variant = .ghost, .size = 13 }).clicked) w.onboarding = .start;
    if (ui.button(c, "Continue", .{ .variant = .primary, .size = 13 }).clicked) w.onboarding = .keys;
}

fn keysStep(c: *ui.Context, w: *Workspace) void {
    title(c, "Keys in the input", "For the input where you type commands and questions. Programs you run (vim, less) keep their own keys.");
    const p = &w.shared.prefs;
    if (choice(c, "ob-keys-std", "keyboard", "Standard", "The Mac's text editing: arrows, ⌥ for words, ⌘ for the line.", false, p.keys == .system)) p.setKeys(.system);
    if (choice(c, "ob-keys-emacs", "command", "Emacs", "^A ^E to the ends, ^K ^U ^W kill and ^Y yanks back, ⌥B ⌥F by words, ^P ^N history.", false, p.keys == .emacs)) p.setKeys(.emacs);
    if (choice(c, "ob-keys-vim", "character.cursor.ibeam", "Vim", "Esc for normal mode: h l w b 0 $, x, dw cw dd cc, p, i a A I; j k through history.", false, p.keys == .vim)) p.setKeys(.vim);
    const f = footer(c);
    defer f.end();
    if (ui.button(c, "Back", .{ .variant = .ghost, .size = 13 }).clicked) w.onboarding = .start;
    if (ui.button(c, "Continue", .{ .variant = .primary, .size = 13 }).clicked) w.onboarding = .analytics;
}

fn analyticsStep(c: *ui.Context, w: *Workspace) void {
    title(c, "Help make nanoterm better", "Share anonymous usage: which features you use (the app opening, prompts sent and to which agent), the app's version and your OS, with a random id for this install. Never your commands, prompts, files, paths or output. Change this any time in Settings.");
    {
        const links = ui.div(c).row().gap(14);
        defer links.end();
        if (ui.button(c, "Privacy Policy", .{ .variant = .ghost, .size = 12, .icon = "hand.raised" }).clicked) _ = nanoui.shell.openUrl(analytics.privacy_url);
        if (ui.button(c, "Terms", .{ .variant = .ghost, .size = 12, .icon = "doc.text" }).clicked) _ = nanoui.shell.openUrl(analytics.terms_url);
    }
    const f = footer(c);
    defer f.end();
    if (ui.button(c, "Back", .{ .variant = .ghost, .size = 13 }).clicked) w.onboarding = .keys;
    if (ui.button(c, "Don't share", .{ .size = 13 }).clicked) finish(w, .off);
    if (ui.button(c, "Share anonymous usage", .{ .variant = .primary, .size = 13 }).clicked) finish(w, .on);
}

/// Done: the choices kept, the window the user's.
fn finish(w: *Workspace, share: @import("settings.zig").Analytics) void {
    const p = &w.shared.prefs;
    p.setAnalytics(share, w.shared.io);
    p.finishOnboarding();
    p.track("onboarding_done", .{ .signed_in = p.account.state == .signed_in, .keys = @tagName(p.keys), .agent = @tagName(p.agent) });
    w.onboarding = .start;
    w.closeOverlay();
}
