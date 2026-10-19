//! Settings' graff providers, signed in to through a stand-in `graff login`
//! (in HOME's .local/bin) that prints what graff prints: xAI's code shown
//! while it waits, then signed in on this device; Kimi's denial shown on its
//! row; signing out removes the credential file. HOME is a temporary folder.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");

const home = "/tmp/nanoterm-test-graff-logins";

// xAI waits for HOME/go (the test's "browser"), then writes its credential;
// Kimi is denied.
const fake_graff =
    \\#!/bin/sh
    \\case "$1 $2" in
    \\"login xai")
    \\  printf '\nTo log in to Grok (xAI), open this URL (browser should open automatically):\n\n  https://accounts.x.ai/device?user_code=ABCD-1234\n\nand confirm the code:  ABCD-1234\n\nwaiting for authorization…\n'
    \\  while [ ! -f "$HOME/go" ]; do sleep 0.05; done
    \\  mkdir -p "$HOME/.xai/credentials"
    \\  echo '{"access_token":"t"}' > "$HOME/.xai/credentials/graff-oauth.json"
    \\  echo "✓ logged in to xAI"
    \\  ;;
    \\"login kimi")
    \\  echo "waiting for authorization…"
    \\  echo "✗ authorization denied"
    \\  exit 1
    \\  ;;
    \\esac
    \\
;

fn waitFor(t: *ui.Tester, w: *ws_mod.Workspace, comptime done: fn (*ui.Tester, *ws_mod.Workspace) bool) !void {
    var waited: f64 = 0;
    while (!done(t, w)) : (waited += 0.02) {
        if (waited > 10) return error.Timeout;
        nanoui.runFor(0.02);
        t.frame();
    }
}

test "graff providers: a code while it waits, signed in, a denial, signed out" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/.local/bin");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/.local/bin/graff", .data = fake_graff, .flags = .{ .permissions = .executable_file } });
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    // The stand-in first: nanoterm adds Homebrew's and others' folders to
    // PATH, where a real graff may be.
    try env.put("PATH", home ++ "/.local/bin:/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    _ = try w.newTab(home);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1000, .height = 1600, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    w.openSettings();
    t.settle(1);
    try std.testing.expect(t.hasText("graff providers"));
    try std.testing.expect(!t.containsText("Signed in"));

    // xAI's Sign in: its row's right end, where ChatGPT's button ends too
    // (Codegraff's own "Sign in" comes first on the page).
    const cg = t.findText("Continue with ChatGPT").?;
    const xai = t.findText("xAI").?;
    t.click(cg.x + cg.w - 12, xai.y + xai.h);
    try waitFor(&t, &w, struct {
        fn ok(x: *ui.Tester, _: *ws_mod.Workspace) bool {
            return x.containsText("ABCD-1234");
        }
    }.ok);
    try std.testing.expectEqualStrings("xai", shared.prefs.graff.flow.?.id);
    try std.testing.expect(t.hasText("Open page") and t.hasText("Cancel"));
    try t.screenshot("/tmp/nanoterm-graff-logins-waiting.png");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/go", .data = "" });
    try waitFor(&t, &w, struct {
        fn ok(x: *ui.Tester, ws: *ws_mod.Workspace) bool {
            return ws.shared.prefs.graff.flow == null and x.hasText("Signed in on this device");
        }
    }.ok);
    try std.testing.expect(t.hasText("Sign in again"));

    // Kimi: denied, and graff's reason on its row.
    try shared.prefs.graff.start(home ++ "/.local/bin/graff", shared.env_list, "kimi");
    try waitFor(&t, &w, struct {
        fn ok(x: *ui.Tester, ws: *ws_mod.Workspace) bool {
            return ws.shared.prefs.graff.flow == null and x.containsText("authorization denied");
        }
    }.ok);
    try std.testing.expectEqualStrings("kimi", shared.prefs.graff.failed_id);
    try t.screenshot("/tmp/nanoterm-graff-logins.png");

    // Signing out of xAI removes its credential file.
    shared.prefs.graff.signOut(null, shared.env_list, "xai");
    t.settle(0.3);
    try std.testing.expect(!t.containsText("Signed in on this device"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, home ++ "/.xai/credentials/graff-oauth.json", .{}));
}
