//! Settings: "Sign in with Codegraff" through the device flow against a
//! fake gateway on this machine (a script: start, two polls, the account's
//! summary, revoke), keeping the key where graff keeps it, only for this
//! user; signing out revokes and removes it. And the page itself, drawn.
//! Nothing reaches Codegraff, and HOME is a temporary folder.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const codegraff = @import("codegraff.zig");
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");

const fake_gateway =
    \\import http.server, json, sys
    \\polls = []
    \\class H(http.server.BaseHTTPRequestHandler):
    \\    def log_message(self, *a): pass
    \\    def reply(self, body):
    \\        data = json.dumps(body).encode()
    \\        self.send_response(200); self.send_header("Content-Type", "application/json")
    \\        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    \\    def do_POST(self):
    \\        n = int(self.headers.get("Content-Length") or 0); body = self.rfile.read(n)
    \\        with open(sys.argv[1] + "/seen", "a") as f: f.write(self.path + " " + (self.headers.get("Authorization") or "") + "\n")
    \\        if self.path == "/v1/device/start":
    \\            self.reply({"device_code": "dc", "user_code": "ABCD-EFGH", "verification_uri": "https://codegraff.com/cli/auth", "verification_uri_complete": "https://codegraff.com/cli/auth?code=ABCD-EFGH", "expires_in": 600, "interval": 1})
    \\        elif self.path == "/v1/device/poll":
    \\            polls.append(1)
    \\            self.reply({"status": "pending"} if len(polls) < 2 else {"status": "ok", "api_key": "cg_sk_test", "email": "me@codegraff.dev"})
    \\        else: self.reply({"ok": True})
    \\    def do_GET(self):
    \\        if self.path == "/v1/usage/summary" and self.headers.get("Authorization") == "Bearer cg_sk_test":
    \\            self.reply({"email": "me@codegraff.dev", "tier": "pro", "credits_micro_usd": 5000000})
    \\        else: self.send_response(401); self.end_headers()
    \\s = http.server.HTTPServer(("127.0.0.1", 0), H)
    \\open(sys.argv[1] + "/port", "w").write(str(s.server_address[1]))
    \\s.serve_forever()
    \\
;

var opened: [128]u8 = undefined;
var opened_len: usize = 0;
fn recordOpen(url: []const u8) void {
    @memcpy(opened[0..url.len], url);
    opened_len = url.len;
}

var jev_key: ?[]const u8 = null;
fn keyChanged(_: *anyopaque, key: ?[]const u8) void {
    jev_key = if (key) |k| (if (std.mem.eql(u8, k, "cg_sk_test")) "cg_sk_test" else "other") else null;
}

fn until(a: *codegraff.Account, comptime ok: fn (*codegraff.Account) bool) !void {
    var waited: f64 = 0;
    while (!ok(a)) : (waited += 0.05) {
        if (waited > 15) return error.Timeout;
        nanoui.runFor(0.05);
    }
}

test "sign in with Codegraff: the device flow keeps graff's key, and signing out revokes it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = "/tmp/nanoterm-test-codegraff";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir ++ "/home");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/gateway.py", .data = fake_gateway });
    var server = try std.process.spawn(io, .{ .argv = &.{ "/usr/bin/python3", "-I", dir ++ "/gateway.py", dir } });
    defer server.kill(io);
    var buf: [16]u8 = undefined;
    var port: []const u8 = "";
    for (0..100) |_| {
        port = std.Io.Dir.cwd().readFile(io, dir ++ "/port", &buf) catch "";
        if (port.len > 0) break;
        nanoui.runFor(0.05);
    }
    try std.testing.expect(port.len > 0);

    var env: std.process.Environ.Map = .init(arena);
    try env.put("NANOTERM_CODEGRAFF_GATEWAY", try std.fmt.allocPrint(arena, "http://127.0.0.1:{s}", .{port}));
    var a: codegraff.Account = .init(gpa, io, dir ++ "/home", &env);
    defer a.deinit();
    a.open = recordOpen;
    var host: u8 = 0;
    a.key_changed = .{ .ctx = &host, .func = keyChanged };
    a.load();
    try std.testing.expectEqual(codegraff.State.signed_out, a.state);

    a.signIn();
    try until(&a, struct {
        fn f(x: *codegraff.Account) bool {
            return x.state == .signed_in and x.credits_micro_usd != null;
        }
    }.f);
    try std.testing.expectEqualStrings("https://codegraff.com/cli/auth?code=ABCD-EFGH", opened[0..opened_len]);
    try std.testing.expectEqualStrings("me@codegraff.dev", a.email.?);
    try std.testing.expectEqualStrings("pro", a.tier.?);
    try std.testing.expectEqual(@as(?i64, 5_000_000), a.credits_micro_usd);
    try std.testing.expectEqualStrings("cg_sk_test", jev_key.?);
    // In graff's file, for this user only.
    const file = dir ++ "/home/" ++ codegraff.key_file;
    var kb: [256]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, try std.Io.Dir.cwd().readFile(io, file, &kb), "\"api_key\": \"cg_sk_test\"") != null);
    const st = try std.Io.Dir.cwd().statFile(io, file, .{});
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(@intFromEnum(st.permissions) & 0o777)));

    // A new launch finds it.
    var again: codegraff.Account = .init(gpa, io, dir ++ "/home", &env);
    defer again.deinit();
    again.load();
    try std.testing.expectEqual(codegraff.State.signed_in, again.state);

    a.signOut();
    try std.testing.expectEqual(codegraff.State.signed_out, a.state);
    try std.testing.expect(jev_key == null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, file, .{}));
    var waited: f64 = 0;
    var seen: []const u8 = "";
    var sb: [1024]u8 = undefined;
    while (waited < 5) : (waited += 0.05) {
        seen = std.Io.Dir.cwd().readFile(io, dir ++ "/seen", &sb) catch "";
        if (std.mem.indexOf(u8, seen, "/v1/keys/revoke Bearer cg_sk_test") != null) break;
        nanoui.runFor(0.05);
    }
    try std.testing.expect(std.mem.indexOf(u8, seen, "/v1/keys/revoke Bearer cg_sk_test") != null);
}

test "the Settings page: account, agents, appearance, updates" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-settings-view";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/.local/bin");
    // graff installed (a stand-in), wherever the test runs.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/.local/bin/graff", .data = "#!/bin/sh\n", .flags = .{ .permissions = .executable_file } });
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    _ = try w.newTab(home);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1000, .height = 1400, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    w.openSettings();
    t.settle(1);
    try std.testing.expect(t.hasText("Sign in with Codegraff"));
    try std.testing.expect(t.hasText("Codex") and t.hasText("opencode") and t.hasText("Hermes"));
    try std.testing.expect(t.hasText("Default"));
    try std.testing.expect(t.containsText("doesn't update itself"));
    try t.screenshot("/tmp/nanoterm-settings.png");
}

fn printed(_: *ui.Tester, s: *session_mod.Session) bool {
    if (s.shell.busy() or s.timeline.items.len == 0) return false;
    return switch (s.timeline.items[s.timeline.items.len - 1]) {
        .block => |b| b.state == .done and b.output.lineCount() > 0,
        else => false,
    };
}

test "a command run in a new tab (an installer, a sign-in) waits for its shell's first prompt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-newtab-run";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    var t: ui.Tester = undefined;
    const s = try w.newTab(home);
    // Before its shell has started.
    try std.testing.expectEqual(@import("shell.zig").Phase.starting, s.shell.phase);
    s.run("printf 'signed in\\n'");
    try t.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 560, .theme = theme.ui() });
    defer t.deinit();
    var waited: f64 = 0;
    while (!printed(&t, s)) : (waited += 0.02) {
        if (waited > 10) return error.Timeout;
        nanoui.runFor(0.02);
        t.frame();
    }
    const b = s.timeline.items[s.timeline.items.len - 1].block;
    const text = try b.output.plainText(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("signed in", text);
}

test "the model picker: graff's models by provider, plans first, with their makers' marks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-models";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    // As graff/models answers: signed-in providers, each row's maker and cost.
    const json =
        \\{"models":[
        \\ {"provider":"codegraff","name":"claude-opus-5-5","maker":"anthropic","context":1000000,"authenticated":true,"cost":"credits"},
        \\ {"provider":"codegraff","name":"kimi-k3","maker":"moonshot","context":262144,"authenticated":true,"cost":"credits"},
        \\ {"provider":"anthropic","name":"claude-sonnet-5-5","maker":"anthropic","context":1000000,"authenticated":true,"cost":"api"},
        \\ {"provider":"chatgpt-new","name":"gpt-6.1-sol","maker":"openai","context":272000,"authenticated":true,"cost":"plan","current":true},
        \\ {"provider":"xai","name":"grok-5","maker":"xai","context":2000000,"authenticated":true,"cost":"plan"},
        \\ {"provider":"mlx","name":"mlx-community/Qwen3.6-27B","context":262144,"authenticated":true,"cost":"local"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, json, .{});
    defer parsed.deinit();
    try shared.catalog.fromAcp(parsed.value);
    shared.catalog.acp = .answered;
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    _ = try w.newTab(home);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 760, .theme = theme.ui() });
    defer t.deinit();
    w.openModels();
    t.settle(1);
    try std.testing.expect(t.hasText("ChatGPT · your plan"));
    try std.testing.expect(t.hasText("xAI · your plan"));
    try std.testing.expect(t.hasText("MLX · local"));
    try std.testing.expect(t.hasText("Codegraff · credits"));
    // Your plans lead (the one in use first); your own keys come last.
    try std.testing.expect(t.findText("ChatGPT · your plan").?.y < t.findText("xAI · your plan").?.y);
    try std.testing.expect(t.findText("xAI · your plan").?.y < t.findText("Codegraff · credits").?.y);
    var marks: usize = 0;
    for (t.ctx.nodes.items) |n| if (n.content == .image) {
        marks += 1;
    };
    try std.testing.expect(marks >= 5);
    try t.screenshot("/tmp/nanoterm-models.png");
}
