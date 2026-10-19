//! The first launch's onboarding, drawn and answered: just the terminal,
//! Vim's keys, no analytics; the answers kept in settings.json. And the
//! keys chosen reaching the input: Vim's normal mode, Emacs's kill and
//! yank. HOME is a temporary folder; nothing is sent anywhere.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const settings = @import("settings.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");

const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    shared: session_mod.Shared,
    w: ws_mod.Workspace,
    t: ui.Tester,

    fn init(f: *Fixture, home: []const u8) !void {
        const gpa = std.testing.allocator;
        const io = std.testing.io;
        f.arena = .init(gpa);
        std.Io.Dir.cwd().deleteTree(io, home) catch {};
        try std.Io.Dir.cwd().createDirPath(io, home);
        f.env = .init(f.arena.allocator());
        try f.env.put("HOME", home);
        try f.env.put("PATH", "/usr/bin:/bin");
        f.shared = try session_mod.Shared.init(gpa, io, f.arena.allocator(), &f.env);
        f.shared.wire();
        f.w = .{ .shared = &f.shared, .nanoapp = undefined };
        _ = try f.w.newTab(home);
        try f.t.init(gpa, .init(&f.w, view.view), .{ .width = 1000, .height = 860, .theme = theme.ui() });
        f.t.settle(1);
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
        f.w.deinit();
        f.shared.deinit();
        f.arena.deinit();
    }
};

test "onboarding: how to start, the input's keys, analytics asked; the answers kept" {
    var f: Fixture = undefined;
    try f.init("/tmp/nanoterm-test-onboarding");
    defer f.deinit();
    const t = &f.t;
    const p = &f.shared.prefs;
    try std.testing.expect(!p.onboarded);
    try std.testing.expectEqual(settings.Analytics.unset, p.analytics);
    f.w.overlay = .onboarding;
    t.settle(1);
    try std.testing.expect(t.hasText("Welcome to nanoterm"));
    try std.testing.expect(t.hasText("Sign in with Codegraff"));
    try std.testing.expect(t.containsText("$1 in free credits"));
    try std.testing.expect(t.hasText("Connect your own agents") and t.hasText("Just the terminal"));
    try t.screenshot("/tmp/nanoterm-onboarding-start.png");
    // Esc and a click outside don't skip it.
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    t.click(8, 8);
    t.settle(0.5);
    try std.testing.expectEqual(ws_mod.Overlay.onboarding, f.w.overlay);

    try t.clickText("Just the terminal");
    t.settle(0.5);
    try std.testing.expect(t.hasText("Keys in the input") and t.hasText("Emacs"));
    try t.clickText("Vim");
    t.settle(0.5);
    try std.testing.expectEqual(ui.Keymap.vim, p.keys);
    try t.clickText("Continue");
    t.settle(0.5);
    try std.testing.expect(t.hasText("Help make nanoterm better") and t.hasText("Privacy Policy"));
    try t.screenshot("/tmp/nanoterm-onboarding-analytics.png");
    try t.clickText("Don't share");
    t.settle(0.5);
    try std.testing.expectEqual(ws_mod.Overlay.none, f.w.overlay);
    try std.testing.expect(p.onboarded);
    try std.testing.expectEqual(settings.Analytics.off, p.analytics);
    // Said no: nothing queued, and no id made.
    try std.testing.expectEqual(@as(usize, 0), p.telemetry.queue.items.len);
    try std.testing.expect(std.mem.allEqual(u8, &p.install_id, '0'));

    var again: settings.Prefs = .init(std.testing.allocator, std.testing.io, f.arena.allocator(), "/tmp/nanoterm-test-onboarding", &f.env);
    defer again.deinit();
    try std.testing.expect(again.onboarded);
    try std.testing.expectEqual(ui.Keymap.vim, again.keys);
    try std.testing.expectEqual(settings.Analytics.off, again.analytics);

    // Turned on later in Settings: an id made, and shown there.
    f.w.openSettings();
    t.settle(1);
    try std.testing.expect(!t.containsText("Install ID"));
    p.setAnalytics(.on, std.testing.io);
    t.settle(0.5);
    try std.testing.expect(t.containsText(&p.install_id));
}

test "the keys chosen reach the input: Vim's normal mode, Emacs's kill and yank" {
    var f: Fixture = undefined;
    try f.init("/tmp/nanoterm-test-input-keys");
    defer f.deinit();
    const t = &f.t;
    const s = f.w.focused();
    f.shared.prefs.setKeys(.vim);
    t.typeText("echo hi there");
    t.settle(0.2);
    try std.testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    t.settle(0.2);
    try std.testing.expect(s.vim_normal);
    try std.testing.expect(t.hasText("NORMAL"));
    t.typeText("bdw");
    t.settle(0.2);
    try std.testing.expectEqualStrings("echo hi ", s.input.text());
    t.typeText("A!");
    t.settle(0.2);
    try std.testing.expect(!s.vim_normal);
    try std.testing.expectEqualStrings("echo hi !", s.input.text());

    f.shared.prefs.setKeys(.emacs);
    try std.testing.expect(t.shortcut(.{ .key = 'u', .ctrl = true }));
    t.settle(0.2);
    try std.testing.expectEqualStrings("", s.input.text());
    try std.testing.expect(t.shortcut(.{ .key = 'y', .ctrl = true }));
    t.settle(0.2);
    try std.testing.expectEqualStrings("echo hi !", s.input.text());
}
