//! show_visual from end to end: nanoterm's MCP server answering MCP, a
//! fake ACP agent that is given that server in `mcpServers` and sends a
//! visual to nanoterm's socket as the server would, the visual in the turn,
//! drawn, and its controls working through the real view. Nothing reaches
//! the user's agents.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const mcp = @import("mcp_server.zig");
const host_mod = @import("visual_host.zig");
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const agent_mod = @import("agent.zig");
const proc = @import("proc.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");

const Recorder = struct {
    sent: *usize,
    pub fn send(r: Recorder, _: std.mem.Allocator, _: []const u8, _: []const u8) struct { []const u8, bool } {
        r.sent.* += 1;
        return .{ "shown", false };
    }
};

fn answer(line: []const u8, sent: *usize) !std.json.Parsed(std.json.Value) {
    const out = mcp.handle(std.testing.allocator, line, Recorder{ .sent = sent }) orelse return error.NoAnswer;
    defer std.testing.allocator.free(out);
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, out, .{});
}

test "the MCP server: initialize, the tool, and calls checked before they're sent" {
    var sent: usize = 0;
    const init = try answer("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\"}}", &sent);
    defer init.deinit();
    try std.testing.expectEqualStrings("2025-03-26", init.value.object.get("result").?.object.get("protocolVersion").?.string);
    try std.testing.expect(mcp.handle(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", Recorder{ .sent = &sent }) == null);

    const list = try answer("{\"jsonrpc\":\"2.0\",\"id\":\"a\",\"method\":\"tools/list\"}", &sent);
    defer list.deinit();
    const tool = list.value.object.get("result").?.object.get("tools").?.array.items[0];
    try std.testing.expectEqualStrings("show_visual", tool.object.get("name").?.string);
    const schema = tool.object.get("inputSchema").?.object;
    try std.testing.expectEqual(false, schema.get("additionalProperties").?.bool);
    try std.testing.expectEqual(@as(usize, 2), schema.get("required").?.array.items.len);

    const Case = struct { args: []const u8, want: []const u8 };
    const bad = [_]Case{
        .{ .args = "{\"title\":\"T\",\"script\":\"return function() return ui.text{text='x', color='red'} end\"}", .want = "styling is not supported" },
        .{ .args = "{\"title\":\"T\",\"script\":\"return function( end\"}", .want = "visual:1:" },
        .{ .args = "{\"title\":\" \",\"script\":\"x\"}", .want = "title must be nonblank" },
        .{ .args = "{\"title\":\"T\",\"script\":\"x\",\"chatId\":\"other\"}", .want = "unknown field 'chatId'" },
    };
    for (bad) |c| {
        const line = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{{\"name\":\"show_visual\",\"arguments\":{s}}}}}", .{c.args});
        defer std.testing.allocator.free(line);
        const r = try answer(line, &sent);
        defer r.deinit();
        const res = r.value.object.get("result").?.object;
        try std.testing.expect(res.get("isError").?.bool);
        const text = res.get("content").?.array.items[0].object.get("text").?.string;
        if (std.mem.indexOf(u8, text, c.want) == null) {
            std.debug.print("got: {s}\n", .{text});
            return error.WrongError;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), sent);
    const ok = try answer("{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"show_visual\",\"arguments\":{\"title\":\"T\",\"script\":\"return function() return ui.text('hi') end\"}}}", &sent);
    defer ok.deinit();
    try std.testing.expectEqual(false, ok.value.object.get("result").?.object.get("isError").?.bool);
    try std.testing.expectEqual(@as(usize, 1), sent);
    const unknown = try answer("{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"resources/list\"}", &sent);
    defer unknown.deinit();
    try std.testing.expectEqual(@as(i64, -32601), unknown.value.object.get("error").?.object.get("code").?.integer);
}

const fake_agent =
    \\import json, socket, sys
    \\def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    \\server = None
    \\script = open(sys.argv[1]).read()
    \\for line in sys.stdin:
    \\    m = json.loads(line)
    \\    method = m.get("method")
    \\    if method == "initialize":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}})
    \\    elif method == "session/new":
    \\        server = m["params"]["mcpServers"][0]
    \\        assert server["name"] == "nanoterm" and server["args"][0] == "--mcp" and server["env"] == []
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s1"}})
    \\    elif method == "session/prompt":
    \\        # What nanoterm's MCP server does with a checked visual.
    \\        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    \\        s.connect(server["args"][1])
    \\        s.sendall((json.dumps({"token": server["args"][2], "title": "Capacity plan", "script": script}) + "\n").encode())
    \\        reply = json.loads(s.makefile().readline())
    \\        s.close()
    \\        bad = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    \\        bad.connect(server["args"][1])
    \\        bad.sendall((json.dumps({"token": "0" * 32, "title": "x", "script": script}) + "\n").encode())
    \\        spoofed = json.loads(bad.makefile().readline())
    \\        text = "shown=%s spoofed=%s" % (reply["ok"], spoofed["ok"])
    \\        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
    \\
;

const capacity =
    \\local capacity = 60
    \\local efficient = true
    \\local saved = 0
    \\return function()
    \\    local rate = if efficient then 0.72 else 1
    \\    local cost = math.floor(capacity * 24 * rate)
    \\    return ui.column {
    \\        ui.text("Synthetic estimates · explore a local capacity plan."),
    \\        ui.row {
    \\            ui.stat { label = "Monthly estimate", value = "$" .. cost },
    \\            ui.stat { label = "Capacity", value = capacity .. " units" },
    \\        },
    \\        ui.chart { label = "Projected monthly cost · USD", values = { math.floor(cost * 0.66), cost, math.floor(cost * 1.15) }, labels = { "Current", "Week 1", "Week 2" } },
    \\        ui.slider { label = "Capacity", value = capacity, min = 10, max = 100, onChange = function(n) capacity = math.floor(n + 0.5) end },
    \\        ui.row {
    \\            ui.toggle { label = "Efficiency mode", value = efficient, onChange = function(b) efficient = b end },
    \\            ui.button { label = "Save scenario", onClick = function() saved += 1 end },
    \\        },
    \\        ui.text(`Saved scenarios: {saved}`),
    \\    }
    \\end
;

fn said(ag: *agent_mod.Agent) []const u8 {
    const t = ag.current() orelse return "";
    for (t.items.items) |it| switch (it) {
        .text => |l| return l.items,
        else => {},
    };
    return "";
}

test "an agent shows a visual, and it works in the conversation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-visual";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/agent.py", .data = fake_agent });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/visual.luau", .data = capacity });
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("TMPDIR", home);
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    try std.testing.expect(shared.visuals != null);
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
    try ag.start(try proc.cStrings(arena, &.{ "/usr/bin/python3", "-I", home ++ "/agent.py", home ++ "/visual.luau" }), try proc.cStrings(arena, &.{"PATH=/usr/bin:/bin"}));
    s.ask("Plan capacity");
    var waited: f64 = 0;
    while (waited < 20) : (waited += 0.02) {
        nanoui.runFor(0.02);
        if (ag.current()) |t| if (t.done) break;
    }
    try std.testing.expectEqualStrings("shown=True spoofed=False", said(ag));

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 900, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("Capacity plan"));
    try std.testing.expect(t.hasText("Monthly estimate: $1036"));
    try std.testing.expect(t.hasText("Capacity: 60 units"));
    try std.testing.expect(t.hasText("Week 1"));
    try std.testing.expect(t.hasText("Saved scenarios: 0"));
    try t.clickText("Save scenario");
    t.settle(1);
    try std.testing.expect(t.hasText("Saved scenarios: 1"));
    // Efficiency off: the estimate is the full rate.
    try t.clickText("Efficiency mode");
    t.settle(1);
    try std.testing.expect(t.hasText("Monthly estimate: $1440"));
    try t.screenshot("/tmp/nanoterm-visual.png");
}

test "nanoterm's MCP server reaches the host over its socket" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const h = try host_mod.Host.create(gpa, io, "/tmp");
    defer h.destroy();
    const Result = struct { text: []const u8 = "", failed: bool = false, done: bool = false, arena: std.heap.ArenaAllocator };
    var result: Result = .{ .arena = .init(gpa) };
    defer result.arena.deinit();
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(path: []const u8, r: *Result) void {
            const sender: mcp.Sender = .{ .path = path, .token = "f0123456789abcdef0123456789abcde" };
            r.text, r.failed = sender.send(r.arena.allocator(), "T", "return function() return ui.text('x') end");
            @atomicStore(bool, &r.done, true, .release);
        }
    }.run, .{ h.path, &result });
    var waited: f64 = 0;
    while (!@atomicLoad(bool, &result.done, .acquire) and waited < 10) : (waited += 0.02) nanoui.runFor(0.02);
    thread.join();
    // No agent has that token: refused, with why.
    try std.testing.expect(result.failed);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "chat context") != null);
}
