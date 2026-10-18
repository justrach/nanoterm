//! nanoterm's tests, without a window: the VT parser, a real zsh cut into
//! blocks by the integration, and the ACP client and host against a fake
//! agent. They use a temporary HOME: the user's rc files and files stay
//! untouched.
const std = @import("std");
const blocks = @import("blocks.zig");
const shell_mod = @import("shell.zig");
const agent_mod = @import("agent.zig");
const proc = @import("proc.zig");

test {
    _ = @import("vt.zig");
    _ = @import("binds.zig");
    _ = @import("find.zig");
    _ = @import("tests_find.zig");
    _ = @import("tests_visual.zig");
    _ = @import("tests_visual_mcp.zig");
    _ = @import("tests_visual_view.zig");
    _ = @import("tests_fold.zig");
    _ = @import("tests_palette.zig");
    _ = @import("tests_pictures.zig");
    _ = @import("tests_pin.zig");
    _ = @import("tests_ssh.zig");
    _ = @import("ssh.zig");
    _ = @import("pictures.zig");
    _ = @import("session_log.zig");
    _ = @import("luau/luau.zig");
    _ = @import("screen.zig");
    _ = @import("screen_vt.zig");
    _ = @import("screen_mouse.zig");
    _ = @import("tests_mouse.zig");
    _ = @import("tests_screen.zig");
    _ = @import("split.zig");
    _ = @import("commands.zig");
    _ = @import("classify.zig");
    _ = @import("history.zig");
    _ = @import("jev.zig");
    _ = @import("agent_config.zig");
    _ = @import("catalog.zig");
    _ = @import("complete.zig");
    _ = @import("palette.zig");
    _ = @import("markdown.zig");
    _ = @import("attach.zig");
    _ = @import("tests_attach.zig");
    _ = @import("blocks.zig");
    _ = @import("highlight.zig");
    _ = @import("tests_view.zig");
    _ = @import("tests_agent.zig");
    _ = @import("tests_stream.zig");
}


/// Runs the main run loop (and so the dispatch sources) until `done`.
fn pumpUntil(ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !void {
    var waited: f64 = 0;
    while (!done(ctx)) : (waited += 0.02) {
        if (waited > 20) return error.Timeout;
        @import("nanoui").runFor(0.02);
    }
}

const Noop = struct {
    fn changed(_: *anyopaque) void {}
    fn exited(_: *anyopaque, _: i32) void {}
};

fn tempHome(io: std.Io, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(gpa, "/tmp/nanoterm-test-{s}", .{name});
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

test "a real zsh, cut into blocks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = try tempHome(io, arena, "shell");

    var sh: shell_mod.Shell = .init(gpa, .{ .ctx = undefined, .changed = Noop.changed, .exited = Noop.exited });
    defer sh.deinit();
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    try sh.start(arena, io, try std.fs.path.join(arena, &.{ home, "zdot" }), home, &env, home, .{ .rows = 24, .cols = 80 });
    try pumpUntil(&sh, struct {
        fn f(s: *shell_mod.Shell) bool {
            return s.phase == .ready;
        }
    }.f);

    const run = struct {
        fn f(s: *shell_mod.Shell, g: std.mem.Allocator, cmd: []const u8) !*blocks.Block {
            const b = try blocks.Block.create(g, 1, .shell, cmd, "/", "");
            s.submit(b);
            try pumpUntil(b, struct {
                fn done(x: *blocks.Block) bool {
                    return x.state == .done;
                }
            }.done);
            // The prompt after it, before the next command.
            try pumpUntil(s, struct {
                fn ready(x: *shell_mod.Shell) bool {
                    return x.phase == .ready;
                }
            }.ready);
            return b;
        }
    }.f;

    const hello = try run(&sh, gpa, "echo hello; echo world");
    defer hello.destroy(gpa);
    const text = try hello.output.plainText(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("hello\nworld", text);
    try std.testing.expectEqual(@as(?i32, 0), hello.exit_code);

    const fails = try run(&sh, gpa, "false");
    defer fails.destroy(gpa);
    try std.testing.expectEqual(@as(?i32, 1), fails.exit_code);

    const colors = try run(&sh, gpa, "printf 'plain \\033[32mgreen\\033[0m\\n'");
    defer colors.destroy(gpa);
    try std.testing.expectEqualStrings("plain green", colors.output.lines.items[0].text.items);
    try std.testing.expectEqual(@as(usize, 1), colors.output.lines.items[0].spans.items.len);

    const cd = try run(&sh, gpa, "cd /tmp");
    defer cd.destroy(gpa);
    try std.testing.expect(std.mem.endsWith(u8, sh.cwd.items, "/tmp"));
}

const fake_agent =
    \\import json, sys
    \\def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    \\def recv():
    \\    line = sys.stdin.readline()
    \\    return json.loads(line) if line else None
    \\while True:
    \\    m = recv()
    \\    if m is None: break
    \\    method = m.get("method")
    \\    if method == "initialize":
    \\        assert m["params"]["clientCapabilities"]["terminal"] is True
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {}}})
    \\    elif method == "session/new":
    \\        assert isinstance(m["params"]["mcpServers"], list), "mcpServers must be a list"
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s1"}})
    \\    elif method == "session/prompt":
    \\        pid = m["id"]
    \\        up = lambda u: send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": u}})
    \\        up({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Running "}})
    \\        up({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "it."}})
    \\        up({"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "echo", "kind": "execute", "status": "in_progress"})
    \\        send({"jsonrpc": "2.0", "id": 100, "method": "terminal/create", "params": {"sessionId": "s1", "command": "echo", "args": ["from the agent"]}})
    \\        tid = recv()["result"]["terminalId"]
    \\        up({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "content": [{"type": "terminal", "terminalId": tid}]})
    \\        send({"jsonrpc": "2.0", "id": 101, "method": "terminal/wait_for_exit", "params": {"sessionId": "s1", "terminalId": tid}})
    \\        code = recv()["result"]["exitCode"]
    \\        send({"jsonrpc": "2.0", "id": 102, "method": "terminal/output", "params": {"sessionId": "s1", "terminalId": tid}})
    \\        out = recv()["result"]["output"]
    \\        up({"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"})
    \\        send({"jsonrpc": "2.0", "id": 103, "method": "session/request_permission", "params": {"sessionId": "s1", "toolCall": {"title": "Write a file"}, "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"}, {"optionId": "no", "name": "Reject", "kind": "reject_once"}]}})
    \\        answer = recv()["result"]["outcome"]["optionId"]
    \\        up({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": " got %r exit %d answer %s" % (out, code, answer)}})
    \\        send({"jsonrpc": "2.0", "id": pid, "result": {"stopReason": "end_turn"}})
    \\
;

const Host = struct {
    gpa: std.mem.Allocator,
    made: std.ArrayList(*blocks.Block) = .empty,
    fn changed(_: *anyopaque) void {}
    fn newBlock(ctx: *anyopaque, command: []const u8, cwd: []const u8) ?*blocks.Block {
        const h: *Host = @ptrCast(@alignCast(ctx));
        const b = blocks.Block.create(h.gpa, h.made.items.len + 1, .agent, command, cwd, "") catch return null;
        h.made.append(h.gpa, b) catch return null;
        return b;
    }
};

test "an ACP agent: messages, a terminal as a block, a permission" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = try tempHome(io, arena, "acp");
    const script = try std.fs.path.join(arena, &.{ home, "fake_agent.py" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script, .data = fake_agent });

    var host: Host = .{ .gpa = gpa };
    defer {
        for (host.made.items) |b| b.destroy(gpa);
        host.made.deinit(gpa);
    }
    const a = try agent_mod.Agent.create(gpa, io, .{ .ctx = &host, .changed = Host.changed, .newBlock = Host.newBlock }, .graff, home);
    defer a.destroy();
    a.env = &.{"PATH=/usr/bin:/bin"};
    try a.start(try proc.cStrings(arena, &.{ "/usr/bin/python3", "-I", script }), try proc.cStrings(arena, &.{"PATH=/usr/bin:/bin"}));
    try a.prompt("run something");
    // Answer the permission when it comes, as the user would.
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            const t = x.current() orelse return false;
            for (t.items.items) |*it| switch (it.*) {
                .permission => |*p| {
                    x.answer(p, 0);
                    return true;
                },
                else => {},
            };
            return t.done;
        }
    }.f);
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            return x.current().?.done;
        }
    }.f);
    const t = a.current().?;
    try std.testing.expectEqual(@as(usize, 1), host.made.items.len);
    const b = host.made.items[0];
    try std.testing.expectEqualStrings("echo from the agent", b.command);
    try std.testing.expectEqual(@as(?i32, 0), b.exit_code);
    var message: []const u8 = "";
    var tool_linked = false;
    for (t.items.items) |it| switch (it) {
        .text => |l| message = l.items,
        .tool => |tl| tool_linked = tl.block == b and tl.status == .completed,
        else => {},
    };
    try std.testing.expect(tool_linked);
    try std.testing.expectEqualStrings(" got 'from the agent\\n' exit 0 answer yes", message);
}

const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");

test "Ghostty's splits and tabs, on real sessions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = try tempHome(io, arena, "workspace");
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();

    const first = try w.newTab(home);
    w.splitFocused(.horizontal); // ⌘D
    const right = w.focused();
    try std.testing.expect(right != first);
    w.splitFocused(.vertical); // ⌘⇧D
    try std.testing.expectEqual(@as(usize, 3), ws_mod.Tree.count(w.tab().tree.root));
    // ⌘] cycles through the panes in order and back.
    w.focusNext(1);
    try std.testing.expectEqual(first, w.focused());
    w.focusNext(-1);
    w.toggleZoom();
    try std.testing.expect(w.tab().zoomed);
    w.toggleZoom();
    w.equalize();
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), w.tab().tree.root.kind.split.ratio, 0.001);
    w.resizeFocused(.left);
    try std.testing.expectApproxEqAbs(@as(f32, 0.45), w.tab().tree.root.kind.split.ratio, 0.001);

    // ⌘T: a second tab, in the focused pane's directory.
    const t2 = try w.newTab(w.focused().cwd());
    try std.testing.expectEqual(@as(usize, 2), w.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), w.active);
    try std.testing.expectEqual(t2, w.focused());
    w.nextTab(1);
    try std.testing.expectEqual(@as(usize, 0), w.active);

    // ⌘W closes panes; the last one closes its tab.
    w.closeFocused();
    try std.testing.expectEqual(@as(usize, 2), ws_mod.Tree.count(w.tab().tree.root));
    w.closeTab(0);
    try std.testing.expectEqual(@as(usize, 1), w.tabs.items.len);
    try std.testing.expectEqual(t2, w.focused());
}
