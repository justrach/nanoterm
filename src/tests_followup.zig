//! One conversation with the agent: after a `cd`, it hears where the
//! terminal is now (and its tools run there); a reply that starts like a
//! command ("go on") stays with it. A fake ACP agent records the prompts;
//! nothing reaches the user's agents. And a Mermaid flowchart too wide for
//! its card is turned and fitted, not cut off.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const agent_mod = @import("agent.zig");
const proc = @import("proc.zig");
const theme = @import("theme.zig");

const fake_agent =
    \\import json, sys
    \\def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    \\n = 0
    \\for line in sys.stdin:
    \\    m = json.loads(line)
    \\    method = m.get("method")
    \\    if method == "initialize":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}})
    \\    elif method == "session/new":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s1"}})
    \\    elif method == "session/prompt":
    \\        n += 1
    \\        text = "".join(b.get("text", "") for b in m["params"]["prompt"])
    \\        open(sys.argv[1] + "/prompt%d" % n, "w").write(text)
    \\        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Which repository?"}}}})
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
    \\
;

fn pump(s: *session_mod.Session, comptime done: fn (*session_mod.Session) bool) !void {
    var waited: f64 = 0;
    while (!done(s)) : (waited += 0.02) {
        if (waited > 20) return error.Timeout;
        nanoui.runFor(0.02);
    }
}

fn turnDone(s: *session_mod.Session) bool {
    const t = (s.agent orelse return false).current() orelse return false;
    return t.done;
}

test "after a cd the agent hears where the terminal is; \"go on\" stays with it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-followup";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/repo");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/agent.py", .data = fake_agent });
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    // As on a machine with Go installed.
    shared.commands.add("go");
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    const s = try w.newTab(home);
    try pump(s, struct {
        fn f(x: *session_mod.Session) bool {
            return x.shell.cwd.items.len > 0 and !x.shell.busy();
        }
    }.f);
    // The agent started while the shell was at home (Return pressed early).
    const ag = try agent_mod.Agent.create(gpa, io, .{ .ctx = s, .changed = session_mod.Session.changed, .newBlock = struct {
        fn f(_: *anyopaque, _: []const u8, _: []const u8) ?*@import("blocks.zig").Block {
            return null;
        }
    }.f }, .graff, s.cwd());
    s.agent = ag;
    try ag.start(try proc.cStrings(arena, &.{ "/usr/bin/python3", "-I", home ++ "/agent.py", home }), try proc.cStrings(arena, &.{"PATH=/usr/bin:/bin"}));

    s.run("cd repo");
    try pump(s, struct {
        fn f(x: *session_mod.Session) bool {
            return std.mem.endsWith(u8, x.cwd(), "/repo") and !x.shell.busy();
        }
    }.f);
    s.ask("map the current repo");
    try pump(s, turnDone);
    var buf: [512]u8 = undefined;
    const first = try std.Io.Dir.cwd().readFile(io, home ++ "/prompt1", &buf);
    try std.testing.expect(std.mem.indexOf(u8, first, "the terminal is now in `") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "/repo`") != null);
    try std.testing.expect(std.mem.endsWith(u8, first, "map the current repo"));
    // The turn shows what was asked, not the note; tools run in repo/.
    try std.testing.expectEqualStrings("map the current repo", ag.current().?.title.?);
    try std.testing.expect(std.mem.endsWith(u8, ag.cwd, "/repo"));

    // A reply: `go` is a command, but "go on" after an answer is for the agent.
    s.input.set("go on");
    s.observe();
    try std.testing.expectEqual(session_mod.Mode.agent, s.mode());
    s.submit();
    try pump(s, struct {
        fn f(x: *session_mod.Session) bool {
            const a = x.agent orelse return false;
            return a.turns.items.len == 2 and a.current().?.done;
        }
    }.f);
    var buf2: [512]u8 = undefined;
    // Already told: the prompt as typed.
    try std.testing.expectEqualStrings("go on", try std.Io.Dir.cwd().readFile(io, home ++ "/prompt2", &buf2));
    // And no `go` block ran.
    for (s.timeline.items) |it| if (it == .block) try std.testing.expect(!std.mem.eql(u8, it.block.command, "go on"));
}

const wide_flow =
    \\```mermaid
    \\flowchart TD
    \\  A[nanoterm and nanomon] --> P[Public API]
    \\  B[counter and gallery] --> P
    \\  C[hello web example] --> P
    \\  D[Application state] --> P
    \\  E[Text system and atlases] --> P
    \\  F[Desktop services] --> P
    \\  G[Platforms everywhere] --> P
    \\  P --> R[Metal renderer]
    \\  P --> L[Linux GTK backend]
    \\```
;

fn drawWide(_: *u8, c: *ui.Context) void {
    const d = ui.div(c).column().wFull().p(20);
    defer d.end();
    @import("view_markdown.zig").markdown(c, wide_flow);
}

test "a flowchart too wide for its card is turned and fitted, not cut off" {
    const gpa = std.testing.allocator;
    var state: u8 = 0;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&state, drawWide), .{ .width = 700, .height = 900, .theme = theme.ui() });
    defer t.deinit();
    t.settle(0.5);
    for ([_][]const u8{ "nanoterm and nanomon", "Platforms everywhere", "Public API", "Linux GTK backend" }) |label| {
        const r = t.findText(label) orelse return error.LabelMissing;
        try std.testing.expect(r.x >= 0 and r.x + r.w <= 700);
    }
    // Turned: the seven sources stacked, the API to their right.
    try std.testing.expect(t.findText("Public API").?.x > t.findText("nanoterm and nanomon").?.x);
    try t.screenshot("/tmp/nanoterm-mermaid-wide.png");
}
