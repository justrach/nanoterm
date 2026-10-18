//! An answer streaming in, as agents send it: chunks of Markdown that end
//! mid-sentence, mid-list and inside an open code fence, drawn after each
//! one through the real view. A fake ACP agent sends them; nothing reaches
//! the user's agents.
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
    \\import json, sys, time
    \\def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    \\chunks = ["## Plan\n\nI'll **che", "ck** the build first.\n\n- read `build", ".zig`\n- run it\n\n```zig\nconst a = 1;\n",
    \\          "const b = 2;\n```\n\nDone: `zig build` passes."]
    \\for line in sys.stdin:
    \\    m = json.loads(line)
    \\    method = m.get("method")
    \\    if method == "initialize":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}})
    \\    elif method == "session/new":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s1"}})
    \\    elif method == "session/prompt":
    \\        for c in chunks:
    \\            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": c}}}})
    \\            time.sleep(0.25)
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
    \\
;

/// The agent's answer so far.
fn said(s: *session_mod.Session) []const u8 {
    const t = (s.agent orelse return "").current() orelse return "";
    for (t.items.items) |it| switch (it) {
        .text => |l| return l.items,
        else => {},
    };
    return "";
}

test "an answer streaming in, drawn after every chunk" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-stream";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/agent.py", .data = fake_agent });
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    const s = try w.newTab(home);
    const ag = try agent_mod.Agent.create(gpa, io, .{ .ctx = s, .changed = session_mod.Session.changed, .newBlock = struct {
        fn f(_: *anyopaque, _: []const u8, _: []const u8) ?*@import("blocks.zig").Block {
            return null;
        }
    }.f }, .graff, home);
    s.agent = ag;
    try ag.start(try proc.cStrings(arena, &.{ "/usr/bin/python3", "-I", home ++ "/agent.py" }), try proc.cStrings(arena, &.{"PATH=/usr/bin:/bin"}));

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 640, .theme = theme.ui() });
    defer t.deinit();
    s.ask("Check the build");

    // Draw while it streams; every partial answer must lay out and paint.
    var frames: usize = 0;
    var mid_fence = false;
    var waited: f64 = 0;
    while (waited < 20) : (waited += 0.02) {
        @import("nanoui").runFor(0.02);
        t.frame();
        frames += 1;
        const text = said(s);
        // Inside the open fence: drawn as code already.
        if (!mid_fence and std.mem.indexOf(u8, text, "const a") != null and std.mem.indexOf(u8, text, "const b") == null) {
            mid_fence = true;
            try std.testing.expect(t.hasText("const a = 1;"));
            try std.testing.expect(t.hasText("Copy"));
            try t.screenshot("/tmp/nanoterm-stream-mid.png");
        }
        if (ag.current()) |turn| if (turn.done) break;
    }
    try std.testing.expect(mid_fence);
    try std.testing.expect(ag.current().?.done);
    t.settle(1);
    // The split bold mark joined once its other half came.
    try std.testing.expect(!t.hasText("I'll **che"));
    try std.testing.expect(t.hasText("Plan"));
    try std.testing.expect(t.hasText("const b = 2;"));
    try t.screenshot("/tmp/nanoterm-stream-done.png");
    try std.testing.expect(frames > 10);
}
