//! Where agents' visuals come in. Each agent is given nanoterm's MCP server
//! (`nanoterm --mcp SOCKET TOKEN`, mcp_server.zig) through ACP's
//! `mcpServers`; its `show_visual` sends the visual here, over a socket in a
//! directory only this user can open, with the agent's token. The visual
//! joins that agent's turn, and the answer (shown, or why not) goes back to
//! the agent. Read on the main thread when it arrives; nothing polls.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const fdwatch = nanoui.fdwatch;
const agent_mod = @import("agent.zig");

extern "c" fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*c_uint) c_int;
extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn rmdir(path: [*:0]const u8) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn getpid() c_int;

const AF_UNIX = 1;
const SOCK_STREAM = 1;
const F_SETFL = 4;
const O_NONBLOCK = if (builtin.os.tag == .linux) 0o4000 else 0x4;
/// A message is at most a visual's script, its title and some JSON.
const max_message = 160 * 1024;

pub const Addr = std.c.sockaddr.un;

/// The socket address of `path`.
pub fn address(path: []const u8) !Addr {
    var a: Addr = .{ .path = @splat(0) };
    if (path.len >= a.path.len) return error.NameTooLong;
    @memcpy(a.path[0..path.len], path);
    return a;
}

/// Connects to the socket at `path` (blocking), for the MCP server.
pub fn dial(path: []const u8) !c_int {
    const a = try address(path);
    const fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return error.Socket;
    errdefer _ = close(fd);
    if (connect(fd, &a, @sizeOf(Addr)) != 0) return error.Connect;
    return fd;
}

pub fn writeAll(fd: c_int, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const n = write(fd, rest.ptr, rest.len);
        if (n <= 0) return false;
        rest = rest[@intCast(n)..];
    }
    return true;
}

/// Reads one line (blocking) into `buf`, without its newline.
pub fn readLine(gpa: std.mem.Allocator, fd: c_int, buf: *std.ArrayList(u8)) !void {
    var chunk: [4096]u8 = undefined;
    while (std.mem.indexOfScalar(u8, buf.items, '\n') == null) {
        const n = read(fd, &chunk, chunk.len);
        if (n <= 0) return error.Closed;
        try buf.appendSlice(gpa, chunk[0..@intCast(n)]);
        if (buf.items.len > max_message) return error.TooLong;
    }
    buf.items.len = std.mem.indexOfScalar(u8, buf.items, '\n').?;
}

const Conn = struct {
    host: *Host,
    fd: c_int,
    watch: ?fdwatch.Watch = null,
    buf: std.ArrayList(u8) = .empty,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: [:0]u8,
    path: [:0]u8,
    fd: c_int = -1,
    watch: ?fdwatch.Watch = null,
    conns: std.ArrayList(*Conn) = .empty,
    agents: std.ArrayList(struct { token: [32]u8, agent: *agent_mod.Agent }) = .empty,

    /// Listens in a new private directory under `tmp`.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, tmp: []const u8) !*Host {
        var rnd: [6]u8 = undefined;
        io.random(&rnd);
        const dir = try std.fmt.allocPrintSentinel(gpa, "{s}/nanoterm-{d}-{x}", .{ std.mem.trimEnd(u8, tmp, "/"), getpid(), rnd }, 0);
        errdefer gpa.free(dir);
        if (mkdir(dir, 0o700) != 0) return error.MakeDir;
        errdefer _ = rmdir(dir);
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/v.sock", .{dir}, 0);
        errdefer gpa.free(path);
        const a = try address(path);
        const fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) return error.Socket;
        errdefer _ = close(fd);
        if (bind(fd, &a, @sizeOf(Addr)) != 0) return error.Bind;
        if (listen(fd, 16) != 0) return error.Listen;
        _ = fcntl(fd, F_SETFL, @as(c_int, O_NONBLOCK));
        const h = try gpa.create(Host);
        h.* = .{ .gpa = gpa, .io = io, .dir = dir, .path = path, .fd = fd };
        h.watch = fdwatch.readable(fd, h, onAccept) catch |e| {
            gpa.destroy(h);
            return e;
        };
        return h;
    }

    pub fn destroy(h: *Host) void {
        if (h.watch) |w| w.cancel();
        for (h.conns.items) |c| h.drop(c, false);
        h.conns.deinit(h.gpa);
        h.agents.deinit(h.gpa);
        _ = close(h.fd);
        _ = unlink(h.path);
        _ = rmdir(h.dir);
        h.gpa.free(h.path);
        h.gpa.free(h.dir);
        h.gpa.destroy(h);
    }

    /// A token for `a`'s MCP server to name it by.
    pub fn register(h: *Host, a: *agent_mod.Agent) ![32]u8 {
        var rnd: [16]u8 = undefined;
        h.io.random(&rnd);
        var token: [32]u8 = undefined;
        _ = std.fmt.bufPrint(&token, "{x}", .{rnd}) catch unreachable;
        try h.agents.append(h.gpa, .{ .token = token, .agent = a });
        return token;
    }

    pub fn forget(h: *Host, a: *agent_mod.Agent) void {
        var i: usize = 0;
        while (i < h.agents.items.len) {
            if (h.agents.items[i].agent == a) _ = h.agents.swapRemove(i) else i += 1;
        }
    }

    fn find(h: *Host, token: []const u8) ?*agent_mod.Agent {
        if (token.len != 32) return null;
        for (h.agents.items) |e| if (std.crypto.timing_safe.eql([32]u8, e.token, token[0..32].*)) return e.agent;
        return null;
    }

    fn onAccept(ctx: ?*anyopaque) callconv(.c) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        while (true) {
            const fd = accept(h.fd, null, null);
            if (fd < 0) return;
            _ = fcntl(fd, F_SETFL, @as(c_int, O_NONBLOCK));
            const c = h.gpa.create(Conn) catch {
                _ = close(fd);
                continue;
            };
            c.* = .{ .host = h, .fd = fd };
            h.conns.append(h.gpa, c) catch {
                h.gpa.destroy(c);
                _ = close(fd);
                continue;
            };
            c.watch = fdwatch.readable(fd, c, onReadable) catch {
                h.drop(c, true);
                continue;
            };
        }
    }

    fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
        const c: *Conn = @ptrCast(@alignCast(ctx));
        const h = c.host;
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            const n = read(c.fd, &chunk, chunk.len);
            if (n == 0) return h.drop(c, true);
            if (n < 0) break;
            c.buf.appendSlice(h.gpa, chunk[0..@intCast(n)]) catch return h.drop(c, true);
            if (c.buf.items.len > max_message) return h.drop(c, true);
        }
        const nl = std.mem.indexOfScalar(u8, c.buf.items, '\n') orelse return;
        const reply = h.handle(c.buf.items[0..nl]);
        var aw: std.Io.Writer.Allocating = .init(h.gpa);
        defer aw.deinit();
        std.json.Stringify.value(.{ .ok = reply.ok, .message = reply.message }, .{}, &aw.writer) catch {};
        aw.writer.writeByte('\n') catch {};
        _ = writeAll(c.fd, aw.written());
        h.drop(c, true);
    }

    const Reply = struct { ok: bool, message: []const u8 };

    fn handle(h: *Host, line: []const u8) Reply {
        var arena: std.heap.ArenaAllocator = .init(h.gpa);
        defer arena.deinit();
        const Msg = struct { token: []const u8, title: []const u8, script: []const u8 };
        const m = std.json.parseFromSliceLeaky(Msg, arena.allocator(), line, .{ .ignore_unknown_fields = true }) catch return .{ .ok = false, .message = "malformed request" };
        const a = h.find(m.token) orelse return .{ .ok = false, .message = "show_visual needs a chat context: this agent is not in a nanoterm conversation" };
        if (a.showVisual(m.title, m.script)) |err| return .{ .ok = false, .message = err };
        return .{ .ok = true, .message = "The visual is shown in the conversation. Its controls run there without another model turn." };
    }

    fn drop(h: *Host, c: *Conn, remove: bool) void {
        if (c.watch) |w| w.cancel();
        _ = close(c.fd);
        c.buf.deinit(h.gpa);
        if (remove) for (h.conns.items, 0..) |x, i| if (x == c) {
            _ = h.conns.swapRemove(i);
            break;
        };
        h.gpa.destroy(c);
    }
};
