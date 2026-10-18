//! An SSH session, end to end, with a fake `ssh` (a local bash standing in
//! for the remote shell; `-- command` runs a command, as ssh does): set up,
//! each remote command is a block with its status and folder; the agent's
//! prompt says where it is, and its commands run "there", in that folder.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const agent_mod = @import("agent.zig");
const proc = @import("proc.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");

const fake_ssh =
    \\#!/bin/bash
    \\for a in "$@"; do
    \\  if [ "$run" = 1 ]; then exec /bin/bash -c "$a"; fi
    \\  [ "$a" = "--" ] && run=1
    \\done
    \\exec /bin/bash --norc --noprofile -i
    \\
;

const fake_agent =
    \\import json, sys
    \\def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    \\def recv():
    \\    l = sys.stdin.readline()
    \\    return json.loads(l) if l else None
    \\while True:
    \\    m = recv()
    \\    if m is None: break
    \\    method = m.get("method")
    \\    if method == "initialize":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}})
    \\    elif method == "session/new":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s1"}})
    \\    elif method == "session/prompt":
    \\        text = m["params"]["prompt"][0]["text"]
    \\        aware = "SSH session on `devbox`" in text
    \\        send({"jsonrpc": "2.0", "id": 100, "method": "terminal/create", "params": {"sessionId": "s1", "command": "/bin/sh", "args": ["-c", "pwd"]}})
    \\        tid = recv()["result"]["terminalId"]
    \\        send({"jsonrpc": "2.0", "id": 101, "method": "terminal/wait_for_exit", "params": {"sessionId": "s1", "terminalId": tid}})
    \\        recv()
    \\        send({"jsonrpc": "2.0", "id": 102, "method": "terminal/output", "params": {"sessionId": "s1", "terminalId": tid}})
    \\        out = recv()["result"]["output"].strip()
    \\        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "aware=%s pwd=%s" % (aware, out)}}}})
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
    \\
;

fn until(t: *ui.Tester, s: *session_mod.Session, comptime ok: fn (*session_mod.Session) bool) bool {
    var waited: f64 = 0;
    while (waited < 15) : (waited += 0.02) {
        nanoui.runFor(0.02);
        t.frame();
        if (ok(s)) return true;
    }
    return false;
}

fn shellReady(s: *session_mod.Session) bool {
    return s.shell.phase == .ready and !s.shell.busy();
}

fn remoteReady(s: *session_mod.Session) bool {
    return s.shell.remoteReady();
}

fn lastBlock(s: *session_mod.Session) *@import("blocks.zig").Block {
    return s.timeline.items[s.timeline.items.len - 1].block;
}

fn lastDone(s: *session_mod.Session) bool {
    return lastBlock(s).state == .done and s.shell.remoteReady();
}

test "an SSH session: set up, remote blocks, and the agent working there" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-ssh";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/bin");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/bin/ssh", .data = fake_ssh, .flags = .{ .permissions = .executable_file } });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/agent.py", .data = fake_agent });
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", home ++ "/bin:/usr/bin:/bin");
    try env.put("TMPDIR", home);
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    const s = try w.newTab(home);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 700, .theme = theme.ui() });
    defer t.deinit();
    try std.testing.expect(until(&t, s, shellReady));

    s.run("ssh devbox");
    try std.testing.expect(s.shell.remote != null);
    // Signed in (here, at once): the bar offers to set it up.
    for (0..40) |_| {
        nanoui.runFor(0.02);
        t.frame();
    }
    try std.testing.expect(t.containsText("Signed in to devbox?"));
    try t.clickText("Set up");
    try std.testing.expect(until(&t, s, remoteReady));
    try std.testing.expect(t.containsText("On devbox"));

    // Each command, a block of its own, on the host.
    s.run("echo hello-remote");
    try std.testing.expect(until(&t, s, lastDone));
    const hello = lastBlock(s);
    try std.testing.expectEqualStrings("hello-remote", hello.output.lines.items[0].text.items);
    try std.testing.expectEqual(@as(?i32, 0), hello.exit_code);
    try std.testing.expect(std.mem.startsWith(u8, hello.cwd, "devbox:"));
    s.run("false");
    try std.testing.expect(until(&t, s, lastDone));
    try std.testing.expectEqual(@as(?i32, 1), lastBlock(s).exit_code);
    s.run("cd /usr");
    try std.testing.expect(until(&t, s, lastDone));
    try std.testing.expectEqualStrings("/usr", s.shell.remote.?.cwd.items);

    // What reads as a question goes to the agent, on the host.
    s.input.set("what is in this folder?");
    try std.testing.expectEqual(session_mod.Mode.agent, s.mode());
    s.input.set("ls -la");
    try std.testing.expectEqual(session_mod.Mode.terminal, s.mode());
    const ag = try agent_mod.Agent.create(gpa, io, .{ .ctx = s, .changed = session_mod.Session.changed, .newBlock = session_mod.Session.agentBlockFn }, .graff, home);
    s.agent = ag;
    ag.env = shared.env_list;
    try ag.start(try proc.cStrings(arena, &.{ "/usr/bin/python3", "-I", home ++ "/agent.py" }), try proc.cStrings(arena, shared.env_list));
    s.ask("what is in this folder?");
    var waited: f64 = 0;
    while (waited < 15) : (waited += 0.02) {
        nanoui.runFor(0.02);
        t.frame();
        if (ag.current()) |turn| if (turn.done) break;
    }
    const turn = ag.current().?;
    var said: []const u8 = "";
    for (turn.items.items) |it| switch (it) {
        .text => |l| said = l.items,
        else => {},
    };
    try std.testing.expectEqualStrings("aware=True pwd=/usr", said);
    // The turn shows what was asked, not the note to the agent.
    try std.testing.expectEqualStrings("what is in this folder?", turn.title.?);
    try t.screenshot("/tmp/nanoterm-ssh.png");
}
