//! The agent on a remote host: when its pane is in an SSH session, the
//! files it reads and writes through nanoterm are the host's, through the
//! session's shared connection (ssh.zig), answered when ssh is done.
const std = @import("std");
const proc = @import("proc.zig");
const ssh = @import("ssh.zig");
const Agent = @import("agent.zig").Agent;

/// Where the agent works: the `ssh …` of the session, the directory of
/// shared connections, the remote folder, the host's name.
pub const Remote = struct {
    session: []u8,
    dir: []u8,
    cwd: []u8,
    host: []u8,

    pub fn deinit(r: Remote, gpa: std.mem.Allocator) void {
        gpa.free(r.session);
        gpa.free(r.dir);
        gpa.free(r.cwd);
        gpa.free(r.host);
    }

    /// `command` as a local command line that runs it on the host.
    pub fn wrap(r: Remote, arena: std.mem.Allocator, command: []const u8) ![]const u8 {
        return ssh.remoteCommand(arena, r.session, r.dir, r.cwd, command);
    }

    /// A path as the host knows it: relative ones from the remote folder.
    fn path(r: Remote, arena: std.mem.Allocator, p: []const u8) ![]const u8 {
        if (std.mem.startsWith(u8, p, "/")) return p;
        return std.fmt.allocPrint(arena, "{s}/{s}", .{ r.cwd, p });
    }
};

/// One ssh doing a file's work: what it printed, and whom to answer.
const Job = struct {
    agent: *Agent,
    process: proc.Process = undefined,
    rpc_id: []u8,
    out: std.ArrayList(u8) = .empty,
    write: bool,

    fn output(ctx: *anyopaque, bytes: []const u8) void {
        const j: *Job = @ptrCast(@alignCast(ctx));
        if (j.out.items.len + bytes.len <= 32 << 20) j.out.appendSlice(j.agent.gpa, bytes) catch {};
    }

    fn exited(ctx: *anyopaque, code: i32) void {
        const j: *Job = @ptrCast(@alignCast(ctx));
        const a = j.agent;
        if (code != 0) {
            const msg = std.mem.trim(u8, j.out.items[0..@min(j.out.items.len, 300)], " \n");
            a.client.respondError(j.rpc_id, -32002, if (msg.len > 0) msg else "the remote command failed");
        } else if (j.write) {
            a.client.respond(j.rpc_id, null);
        } else a.client.respond(j.rpc_id, .{ .content = j.out.items });
        // Freed once its process is: after this callback returns.
        a.gpa.free(j.rpc_id);
        j.out.deinit(a.gpa);
        j.process.close();
        a.gpa.destroy(j);
    }
};

fn start(a: *Agent, id: []const u8, line: []const u8, write: bool, input: ?[]const u8, arena: std.mem.Allocator) void {
    const j = a.gpa.create(Job) catch return a.client.respondError(id, -32603, "out of memory");
    j.* = .{ .agent = a, .rpc_id = a.gpa.dupe(u8, id) catch {
        a.gpa.destroy(j);
        return a.client.respondError(id, -32603, "out of memory");
    }, .write = write };
    const argv = proc.cStrings(arena, &.{ "/bin/sh", "-c", line }) catch return;
    const envp = proc.cStrings(arena, a.env) catch return;
    const cwd = arena.dupeSentinel(u8, a.cwd, 0) catch return;
    // A read keeps ssh's own messages out of the file's content.
    proc.spawnPipes(&j.process, argv, envp, cwd, write, .{ .ctx = j, .output = Job.output, .exited = Job.exited }) catch {
        a.client.respondError(id, -32603, "could not start ssh");
        a.gpa.free(j.rpc_id);
        a.gpa.destroy(j);
        return;
    };
    if (input) |bytes| j.process.send(bytes);
    j.process.closeInput();
}

/// `fs/read_text_file` on the host (the whole file; ACP's line and limit
/// are applied by `cat`'s callers rarely enough to read it all).
pub fn readFile(a: *Agent, r: Remote, id: []const u8, file: []const u8, arena: std.mem.Allocator) void {
    const p = r.path(arena, file) catch return;
    const cmd = std.fmt.allocPrint(arena, "cat -- {s}", .{ssh.quote(arena, p) catch return}) catch return;
    start(a, id, r.wrap(arena, cmd) catch return, false, null, arena);
}

/// `fs/write_text_file` on the host: its folders made, then the file.
pub fn writeFile(a: *Agent, r: Remote, id: []const u8, file: []const u8, content: []const u8, arena: std.mem.Allocator) void {
    const p = r.path(arena, file) catch return;
    const q = ssh.quote(arena, p) catch return;
    const dir = ssh.quote(arena, std.fs.path.dirname(p) orelse ".") catch return;
    const cmd = std.fmt.allocPrint(arena, "mkdir -p {s} && cat > {s}", .{ dir, q }) catch return;
    start(a, id, r.wrap(arena, cmd) catch return, true, content, arena);
}
