//! What a session does for its agent: points it at the SSH host it is on,
//! gives it nanoterm's MCP server (visuals), and keeps its finished turns
//! in the session history.
const std = @import("std");
const agent_mod = @import("agent.zig");
const ssh = @import("ssh.zig");
const visual_host = @import("visual_host.zig");
const Session = @import("session.zig").Session;

/// Points the agent at the SSH host of this pane, or at this machine.
pub fn syncRemote(a: *Session, ag: *agent_mod.Agent) void {
    if (ag.remote) |old| old.deinit(a.gpa);
    ag.remote = null;
    const r = a.shell.remote orelse return;
    if (!r.active) return;
    var buf: [128]u8 = undefined;
    const dir = ssh.ensureDir(&buf);
    ag.remote = .{
        .session = a.gpa.dupe(u8, r.command) catch return,
        .dir = a.gpa.dupe(u8, dir) catch return,
        .cwd = a.gpa.dupe(u8, if (r.cwd.items.len > 0) r.cwd.items else ".") catch return,
        .host = a.gpa.dupe(u8, r.host) catch return,
    };
}

/// Keeps the agent where the shell is: when the shell has moved since the
/// agent last heard (a `cd` after it started), its tools run in the new
/// directory, and the prompt says so; else the prompt as it is.
pub fn followShell(a: *Session, ag: *agent_mod.Agent, text: []const u8) []const u8 {
    const now = a.cwd();
    if (std.mem.eql(u8, now, ag.cwd)) return text;
    const said = std.fmt.allocPrint(a.arena, "[nanoterm: the terminal is now in `{s}` (it was `{s}`); work there.]\n\n{s}", .{ now, ag.cwd, text }) catch return text;
    const dupe = a.gpa.dupe(u8, now) catch return text;
    a.gpa.free(ag.cwd);
    ag.cwd = dupe;
    return said;
}

/// Gives the agent nanoterm's MCP server, so it can show visuals here.
pub fn offerVisuals(a: *Session, ag: *agent_mod.Agent) void {
    const h = a.shared.visuals orelse return;
    if (a.shared.exe.len == 0) return;
    const token = h.register(ag) catch return;
    const args = a.arena.alloc([]const u8, 3) catch return;
    args[0] = "--mcp";
    args[1] = h.path;
    args[2] = a.arena.dupe(u8, &token) catch return;
    ag.mcp = .{ .name = "nanoterm", .command = a.shared.exe, .args = args };
    ag.on_destroy = .{ .ctx = h, .func = forgetAgent };
}

fn forgetAgent(ctx: *anyopaque, ag: *agent_mod.Agent) void {
    const h: *visual_host.Host = @ptrCast(@alignCast(ctx));
    h.forget(ag);
}

/// A turn ended: into the session history, with where it lives.
pub fn finished(ctx: *anyopaque, t: *agent_mod.Turn) void {
    const a: *Session = @ptrCast(@alignCast(ctx));
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(a.gpa);
    const items = t.items.items;
    var i = @import("view_fold.zig").replyStart(items);
    while (i < items.len) : (i += 1) switch (items[i]) {
        .text => |l| reply.appendSlice(a.gpa, l.items) catch {},
        else => {},
    };
    if (reply.items.len == 0) for (items) |it| switch (it) {
        .visual => |sv| reply.appendSlice(a.gpa, sv.title) catch {},
        .note => |n| reply.appendSlice(a.gpa, n) catch {},
        else => {},
    };
    a.shared.log.record(.{
        .time = @import("session_log.zig").now(a.io),
        .cwd = @constCast(a.cwd()),
        .agent = @constCast(t.agent.label()),
        .prompt = t.prompt,
        .reply = reply.items,
        .session = a.id,
        .turn = t,
    });
}

