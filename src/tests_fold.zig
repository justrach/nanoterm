//! A turn reads as Harness's do: the agent's steps (thoughts, tools, the
//! narration between them) fold into one line saying what it did; the
//! visual and the reply stay in view; a click opens the steps.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const agent_mod = @import("agent.zig");
const proc = @import("proc.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");

const fake_agent =
    \\import json, socket, sys
    \\def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    \\def up(u): send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": u}})
    \\server = None
    \\for line in sys.stdin:
    \\    m = json.loads(line)
    \\    method = m.get("method")
    \\    if method == "initialize":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}})
    \\    elif method == "session/new":
    \\        server = m["params"]["mcpServers"][0]
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s1"}})
    \\    elif method == "session/prompt":
    \\        up({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "Evaluating display options"}})
    \\        up({"sessionUpdate": "tool_call", "toolCallId": "r1", "title": "README.md", "kind": "read", "status": "completed",
    \\            "content": [{"type": "content", "content": {"type": "text", "text": "# nanoui"}}]})
    \\        up({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "I'll illustrate it."}})
    \\        up({"sessionUpdate": "tool_call", "toolCallId": "v1", "title": "show_visual", "kind": "other", "status": "in_progress"})
    \\        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    \\        s.connect(server["args"][1])
    \\        script = "return function() return ui.stat{label='Paths', value=2} end"
    \\        s.sendall((json.dumps({"token": server["args"][2], "title": "How nanoui works", "script": script}) + "\n").encode())
    \\        s.makefile().readline()
    \\        up({"sessionUpdate": "tool_call_update", "toolCallId": "v1", "status": "completed"})
    \\        up({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Here it is: two paths."}})
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
    \\
;

test "the agent's steps fold into one line; the visual and reply stay" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-fold";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/agent.py", .data = fake_agent });
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("TMPDIR", home);
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    const s = try w.newTab(home);
    const ag = try agent_mod.Agent.create(gpa, io, .{ .ctx = s, .changed = session_mod.Session.changed, .newBlock = struct {
        fn f(_: *anyopaque, _: []const u8, _: []const u8) ?*@import("blocks.zig").Block {
            return null;
        }
    }.f }, .graff, home);
    s.agent = ag;
    s.offerVisuals(ag);
    try ag.start(try proc.cStrings(arena, &.{ "/usr/bin/python3", "-I", home ++ "/agent.py" }), try proc.cStrings(arena, &.{"PATH=/usr/bin:/bin"}));
    s.ask("Show me how this works");
    var waited: f64 = 0;
    while (waited < 20) : (waited += 0.02) {
        nanoui.runFor(0.02);
        if (ag.current()) |t| if (t.done) break;
    }
    try std.testing.expect(ag.current().?.done);

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 700, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    const line = "Thought process · wrote a note · read 1 file";
    try std.testing.expect(t.hasText(line));
    try std.testing.expect(t.hasText("How nanoui works"));
    try std.testing.expect(t.hasText("Here it is: two paths."));
    try std.testing.expect(!t.hasText("README.md"));
    try std.testing.expect(!t.containsText("Evaluating display options"));
    try std.testing.expect(!t.hasText("show_visual"));
    try t.screenshot("/tmp/nanoterm-fold-closed.png");
    try t.clickText(line);
    t.settle(1);
    try std.testing.expect(t.hasText("README.md"));
    try std.testing.expect(t.containsText("Evaluating display options"));
    try std.testing.expect(t.hasText("I'll illustrate it."));
    try t.screenshot("/tmp/nanoterm-fold-open.png");
}
