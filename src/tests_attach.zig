//! Markdown printed by `cat`, drawn as Markdown; pictures in the input,
//! shown as chips and sent to the agent as ACP image blocks. Through the
//! real view in ui.Tester, and a fake agent: no clipboard, no real agent.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const agent_mod = @import("agent.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");
const proc = @import("proc.zig");

const readme =
    \\# Release notes
    \\
    \\Text in **bold** and `code`.
    \\
    \\- first point
    \\- second point
;

const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR";

test "cat of a Markdown file is drawn as Markdown; pictures wait as chips" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-attach";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/shot.png", .data = png });
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
    // A block as the shell would have filled it; no command runs.
    const b = s.newBlock(.shell, "cat README.md", home).?;
    try b.output.feed(readme ++ "\n");
    b.finish(0);
    try s.timeline.append(gpa, .{ .block = b });

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 700, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(t.hasText("Release notes"));
    try std.testing.expect(!t.containsText("# Release notes"));
    try std.testing.expect(!t.containsText("**bold**"));
    try t.screenshot("/tmp/nanoterm-view-cat-markdown.png");
    // Raw shows the file as it was.
    b.raw = true;
    t.settle(1);
    try std.testing.expect(t.hasText("# Release notes"));
    // Another file stays text.
    b.raw = false;
    gpa.free(b.command);
    b.command = try gpa.dupe(u8, "cat notes.txt");
    t.settle(1);
    try std.testing.expect(t.hasText("# Release notes"));

    // Pictures: a chip each, sent to the agent, ✕ leaves one out.
    try std.testing.expect(s.attachments.addPath(io, home ++ "/shot.png"));
    try std.testing.expect(s.attachments.addPasted(io, png));
    try std.testing.expect(!s.attachments.addPath(io, home ++ "/missing.png"));
    t.settle(1);
    try std.testing.expect(t.hasText("shot.png"));
    try std.testing.expect(t.hasText("Pasted image.png"));
    try std.testing.expect(t.hasText("could not read the file"));
    try std.testing.expectEqual(session_mod.Mode.agent, s.mode());
    try t.screenshot("/tmp/nanoterm-view-pictures.png");
    s.attachments.remove(0);
    t.settle(1);
    try std.testing.expect(!t.hasText("shot.png"));
    try std.testing.expect(t.hasText("Pasted image.png"));
}

const fake_agent =
    \\import json, sys
    \\def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    \\for line in sys.stdin:
    \\    m = json.loads(line)
    \\    method = m.get("method")
    \\    if method == "initialize":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {"promptCapabilities": {"image": True}}}})
    \\    elif method == "session/new":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s1"}})
    \\    elif method == "session/prompt":
    \\        got = " ".join(p["type"] + (":" + p["mimeType"] + ":" + p["data"] + ":" + p.get("uri", "") if p["type"] == "image" else ":" + p["text"]) for p in m["params"]["prompt"])
    \\        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {
    \\            "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": got}}}})
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
    \\
;

const Host = struct {
    fn changed(_: *anyopaque) void {}
    fn newBlock(_: *anyopaque, _: []const u8, _: []const u8) ?*@import("blocks.zig").Block {
        return null;
    }
};

test "pictures go to the agent as image blocks" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = "/tmp/nanoterm-test-images";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/agent.py", .data = fake_agent });
    var host: u8 = 0;
    const a = try agent_mod.Agent.create(gpa, io, .{ .ctx = &host, .changed = Host.changed, .newBlock = Host.newBlock }, .claude, dir);
    defer a.destroy();
    try a.start(try proc.cStrings(arena, &.{ "/usr/bin/python3", "-I", dir ++ "/agent.py" }), try proc.cStrings(arena, &.{"PATH=/usr/bin:/bin"}));
    // Sent before the session opens: it waits, pictures and all.
    var tray: @import("attach.zig").Tray = .{ .gpa = gpa };
    defer tray.deinit();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/a.png", .data = png });
    try std.testing.expect(tray.addPath(io, dir ++ "/a.png"));
    try a.promptWith(null, "what is this?", tray.take());
    var waited: f64 = 0;
    while (a.current().?.done == false) : (waited += 0.02) {
        if (waited > 20) return error.Timeout;
        nanoui.runFor(0.02);
    }
    try std.testing.expect(a.images_ok);
    const items = a.current().?.items.items;
    try std.testing.expect(items.len > 0 and items[0] == .text);
    var b64: [64]u8 = undefined;
    // Inline with its file's uri, and no trailer: it all went inline.
    const want = try std.fmt.allocPrint(arena, "text:what is this? image:image/png:{s}:file://" ++ dir ++ "/a.png", .{std.base64.standard.Encoder.encode(&b64, png)});
    try std.testing.expectEqualStrings(want, items[0].text.items);
}
