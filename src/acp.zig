//! An Agent Client Protocol client: JSON-RPC 2.0 over an agent's stdin and
//! stdout, one message per line. Requests carry a callback for their
//! response; the agent's own requests (permissions, files, terminals) and
//! notifications (session updates) go to the handler.
const std = @import("std");
const proc = @import("proc.zig");

pub const protocol_version = 1;

/// A response: `result`, or `err` with its message. Both live in `arena`,
/// freed when the callback returns.
pub const Callback = *const fn (ctx: *anyopaque, result: ?std.json.Value, err: ?[]const u8, arena: std.mem.Allocator) void;

const Pending = struct { ctx: *anyopaque, func: Callback };

pub const Handler = struct {
    ctx: *anyopaque,
    /// A request from the agent; answer with `respond` or `respondError`
    /// using `id`, the request's id as JSON (now or later).
    request: *const fn (ctx: *anyopaque, id: []const u8, method: []const u8, params: std.json.Value, arena: std.mem.Allocator) void,
    notification: *const fn (ctx: *anyopaque, method: []const u8, params: std.json.Value, arena: std.mem.Allocator) void,
    exited: *const fn (ctx: *anyopaque, code: i32) void,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    process: proc.Process = undefined,
    handler: Handler,
    line: std.ArrayList(u8) = .empty,
    next_id: i64 = 1,
    pending: std.AutoHashMapUnmanaged(i64, Pending) = .empty,
    alive: bool = false,
    /// What the agent wrote to stderr, for errors.
    stderr: proc.Tail,

    pub fn init(gpa: std.mem.Allocator, handler: Handler) Client {
        return .{ .gpa = gpa, .handler = handler, .stderr = .{ .gpa = gpa } };
    }

    pub fn deinit(c: *Client) void {
        if (c.alive) c.process.close();
        c.alive = false;
        c.line.deinit(c.gpa);
        c.pending.deinit(c.gpa);
        c.stderr.deinit();
    }

    pub fn start(c: *Client, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: [*:0]const u8) !void {
        try c.stderr.open();
        try proc.spawnPipesErr(&c.process, argv, envp, cwd, false, c.stderr.write_fd, .{ .ctx = c, .output = onOutput, .exited = onExited });
        c.stderr.closeWriteEnd();
        c.alive = true;
    }

    fn send(c: *Client, bytes: []const u8) void {
        if (c.alive) c.process.send(bytes);
    }

    /// Sends a request; `func` gets its response.
    pub fn request(c: *Client, method: []const u8, params: anytype, ctx: *anyopaque, func: Callback) !void {
        const id = c.next_id;
        c.next_id += 1;
        var aw: std.Io.Writer.Allocating = .init(c.gpa);
        defer aw.deinit();
        try aw.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id});
        try std.json.Stringify.encodeJsonString(method, .{}, &aw.writer);
        try aw.writer.writeAll(",\"params\":");
        try std.json.Stringify.value(params, .{}, &aw.writer);
        try aw.writer.writeAll("}\n");
        try c.pending.put(c.gpa, id, .{ .ctx = ctx, .func = func });
        c.send(aw.written());
    }

    pub fn notify(c: *Client, method: []const u8, params: anytype) !void {
        var aw: std.Io.Writer.Allocating = .init(c.gpa);
        defer aw.deinit();
        try aw.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
        try std.json.Stringify.encodeJsonString(method, .{}, &aw.writer);
        try aw.writer.writeAll(",\"params\":");
        try std.json.Stringify.value(params, .{}, &aw.writer);
        try aw.writer.writeAll("}\n");
        c.send(aw.written());
    }

    /// What a request with nothing to return answers: `{}`, as ACP's schema
    /// has it (an empty `.{}` is a tuple, which std.json writes as `[]`;
    /// `null` is refused by agents that check types).
    pub const Empty = struct {};

    /// Answers the agent's request `id` (JSON, as the handler got it).
    pub fn respond(c: *Client, id: []const u8, result: anytype) void {
        var aw: std.Io.Writer.Allocating = .init(c.gpa);
        defer aw.deinit();
        aw.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":", .{id}) catch return;
        std.json.Stringify.value(result, .{}, &aw.writer) catch return;
        aw.writer.writeAll("}\n") catch return;
        c.send(aw.written());
    }

    pub fn respondError(c: *Client, id: []const u8, code: i32, message: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(c.gpa);
        defer aw.deinit();
        aw.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":", .{ id, code }) catch return;
        std.json.Stringify.encodeJsonString(message, .{}, &aw.writer) catch return;
        aw.writer.writeAll("}}\n") catch return;
        c.send(aw.written());
    }

    fn onOutput(ctx: *anyopaque, bytes: []const u8) void {
        const c: *Client = @ptrCast(@alignCast(ctx));
        c.line.appendSlice(c.gpa, bytes) catch return;
        while (std.mem.indexOfScalar(u8, c.line.items, '\n')) |nl| {
            const msg = c.line.items[0..nl];
            if (std.mem.trim(u8, msg, " \r").len > 0) c.dispatch(msg);
            const rest = c.line.items.len - nl - 1;
            std.mem.copyForwards(u8, c.line.items[0..rest], c.line.items[nl + 1 ..]);
            c.line.items.len = rest;
        }
    }

    fn onExited(ctx: *anyopaque, code: i32) void {
        const c: *Client = @ptrCast(@alignCast(ctx));
        c.alive = false;
        // Requests still waiting will never be answered.
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        var it = c.pending.iterator();
        while (it.next()) |e| e.value_ptr.func(e.value_ptr.ctx, null, "the agent exited", arena.allocator());
        c.pending.clearRetainingCapacity();
        c.handler.exited(c.handler.ctx, code);
    }

    fn dispatch(c: *Client, msg: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, msg, .{}) catch return;
        if (v != .object) return;
        const o = v.object;
        const method = if (o.get("method")) |m| (if (m == .string) m.string else null) else null;
        const id = o.get("id");
        const params = o.get("params") orelse .null;
        if (method) |m| {
            if (id) |i| {
                const id_json = std.json.Stringify.valueAlloc(a, i, .{}) catch return;
                c.handler.request(c.handler.ctx, id_json, m, params, a);
            } else c.handler.notification(c.handler.ctx, m, params, a);
            return;
        }
        // A response to one of ours.
        const i = id orelse return;
        if (i != .integer) return;
        const p = c.pending.fetchRemove(i.integer) orelse return;
        if (o.get("error")) |e| {
            const text = if (e == .object) if (e.object.get("message")) |m| (if (m == .string) m.string else "error") else "error" else "error";
            p.value.func(p.value.ctx, null, text, a);
        } else p.value.func(p.value.ctx, o.get("result") orelse .null, null, a);
    }
};

/// The string field `key` of JSON object `v`, or null.
pub fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

pub fn obj(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

pub fn int(v: std.json.Value, key: []const u8) ?i64 {
    const f = obj(v, key) orelse return null;
    return if (f == .integer) f.integer else null;
}
