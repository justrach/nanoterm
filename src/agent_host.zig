//! What nanoterm does for an agent, as the ACP client: answer permission
//! questions (asked in the conversation), read and write files, and run
//! commands in terminals, which show as blocks in the agent's turn.
const std = @import("std");
const acp = @import("acp.zig");
const proc = @import("proc.zig");
const blocks = @import("blocks.zig");
const agent_mod = @import("agent.zig");
const Agent = agent_mod.Agent;

pub const Terminal = struct {
    agent: *Agent,
    id: []u8,
    process: proc.Process = undefined,
    block: *blocks.Block,
    output_limit: usize,
    /// `terminal/wait_for_exit` requests waiting, as JSON ids.
    waiting: std.ArrayList([]u8) = .empty,
};

pub const Terminals = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(*Terminal) = .empty,
    next: u32 = 1,

    pub fn init(gpa: std.mem.Allocator) Terminals {
        return .{ .gpa = gpa };
    }

    pub fn deinit(ts: *Terminals) void {
        for (ts.list.items) |t| free(ts.gpa, t);
        ts.list.deinit(ts.gpa);
    }

    fn free(gpa: std.mem.Allocator, t: *Terminal) void {
        t.process.close();
        for (t.waiting.items) |w| gpa.free(w);
        t.waiting.deinit(gpa);
        gpa.free(t.id);
        gpa.destroy(t);
    }

    pub fn find(ts: *Terminals, id: []const u8) ?*Terminal {
        for (ts.list.items) |t| if (std.mem.eql(u8, t.id, id)) return t;
        return null;
    }

    pub fn block(ts: *Terminals, id: []const u8) ?*blocks.Block {
        return if (ts.find(id)) |t| t.block else null;
    }

    fn release(ts: *Terminals, id: []const u8) void {
        for (ts.list.items, 0..) |t, i| if (std.mem.eql(u8, t.id, id)) {
            _ = ts.list.orderedRemove(i);
            free(ts.gpa, t);
            return;
        };
    }
};

pub fn onRequest(ctx: *anyopaque, id: []const u8, method: []const u8, params: std.json.Value, arena: std.mem.Allocator) void {
    const a: *Agent = @ptrCast(@alignCast(ctx));
    const eq = std.mem.eql;
    if (eq(u8, method, "session/request_permission")) {
        permission(a, id, params) catch a.client.respondError(id, -32603, "internal error");
    } else if (eq(u8, method, "fs/read_text_file")) {
        readFile(a, id, params, arena);
    } else if (eq(u8, method, "fs/write_text_file")) {
        writeFile(a, id, params, arena);
    } else if (eq(u8, method, "terminal/create")) {
        createTerminal(a, id, params, arena) catch |err| a.client.respondError(id, -32603, @errorName(err));
    } else if (eq(u8, method, "terminal/output")) {
        const t = terminal(a, id, params) orelse return;
        terminalOutput(a, id, t, arena);
    } else if (eq(u8, method, "terminal/wait_for_exit")) {
        const t = terminal(a, id, params) orelse return;
        if (t.process.exit_code) |code| {
            a.client.respond(id, .{ .exitCode = code, .signal = null });
        } else {
            const copy = a.gpa.dupe(u8, id) catch return;
            t.waiting.append(a.gpa, copy) catch a.gpa.free(copy);
        }
    } else if (eq(u8, method, "terminal/kill")) {
        const t = terminal(a, id, params) orelse return;
        t.process.signal(proc.SIGTERM);
        a.client.respond(id, null);
    } else if (eq(u8, method, "terminal/release")) {
        const tid = acp.str(params, "terminalId") orelse return a.client.respondError(id, -32602, "no terminalId");
        a.terminals.release(tid);
        a.client.respond(id, null);
    } else {
        a.client.respondError(id, -32601, "method not found");
    }
    a.app.changed(a.app.ctx);
}

fn permission(a: *Agent, id: []const u8, params: std.json.Value) !void {
    const t = a.current() orelse return a.client.respond(id, .{ .outcome = .{ .outcome = "cancelled" } });
    const tc = acp.obj(params, "toolCall") orelse .null;
    const title = acp.str(tc, "title") orelse "The agent asks to go on";
    var options: std.ArrayList(agent_mod.Option) = .empty;
    if (acp.obj(params, "options")) |opts| if (opts == .array) for (opts.array.items) |o| {
        try options.append(a.gpa, .{
            .id = try a.gpa.dupe(u8, acp.str(o, "optionId") orelse continue),
            .name = try a.gpa.dupe(u8, acp.str(o, "name") orelse "?"),
            .kind = try a.gpa.dupe(u8, acp.str(o, "kind") orelse "allow_once"),
        });
    };
    a.addItem(t, .{ .permission = .{
        .rpc_id = try a.gpa.dupe(u8, id),
        .title = try a.gpa.dupe(u8, title),
        .options = try options.toOwnedSlice(a.gpa),
    } });
}

fn readFile(a: *Agent, id: []const u8, params: std.json.Value, arena: std.mem.Allocator) void {
    const path = acp.str(params, "path") orelse return a.client.respondError(id, -32602, "no path");
    if (a.remote) |r| return @import("agent_remote.zig").readFile(a, r, id, path, arena);
    const data = std.Io.Dir.cwd().readFileAlloc(a.io, path, arena, .limited(32 << 20)) catch |err|
        return a.client.respondError(id, -32002, @errorName(err));
    // `line` (1-based) and `limit` select lines.
    const first: usize = @intCast(@max(1, acp.int(params, "line") orelse 1));
    const limit: ?usize = if (acp.int(params, "limit")) |l| @intCast(@max(0, l)) else null;
    if (first == 1 and limit == null) return a.client.respond(id, .{ .content = data });
    var start: usize = 0;
    var line: usize = 1;
    while (line < first and start < data.len) : (line += 1) {
        start = if (std.mem.indexOfScalarPos(u8, data, start, '\n')) |nl| nl + 1 else data.len;
    }
    var end = start;
    var taken: usize = 0;
    while (end < data.len and (limit == null or taken < limit.?)) : (taken += 1) {
        end = if (std.mem.indexOfScalarPos(u8, data, end, '\n')) |nl| nl + 1 else data.len;
    }
    a.client.respond(id, .{ .content = data[start..end] });
}

fn writeFile(a: *Agent, id: []const u8, params: std.json.Value, arena: std.mem.Allocator) void {
    const path = acp.str(params, "path") orelse return a.client.respondError(id, -32602, "no path");
    const content = acp.str(params, "content") orelse "";
    if (a.remote) |r| return @import("agent_remote.zig").writeFile(a, r, id, path, content, arena);
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(a.io, dir) catch {};
    cwd.writeFile(a.io, .{ .sub_path = path, .data = content }) catch |err|
        return a.client.respondError(id, -32603, @errorName(err));
    a.client.respond(id, null);
}

fn terminal(a: *Agent, id: []const u8, params: std.json.Value) ?*Terminal {
    const tid = acp.str(params, "terminalId") orelse {
        a.client.respondError(id, -32602, "no terminalId");
        return null;
    };
    return a.terminals.find(tid) orelse {
        a.client.respondError(id, -32602, "no such terminal");
        return null;
    };
}

fn createTerminal(a: *Agent, id: []const u8, params: std.json.Value, arena: std.mem.Allocator) !void {
    const command = acp.str(params, "command") orelse return error.NoCommand;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(arena, command);
    var shown: std.ArrayList(u8) = .empty;
    try shown.appendSlice(arena, command);
    if (acp.obj(params, "args")) |args| if (args == .array) for (args.array.items) |arg| {
        if (arg != .string) continue;
        try argv.append(arena, arg.string);
        try shown.append(arena, ' ');
        try shown.appendSlice(arena, arg.string);
    };
    // `sh -c "…"` shows as the command it runs.
    const label = if (argv.items.len == 3 and std.mem.eql(u8, argv.items[1], "-c")) argv.items[2] else shown.items;
    var cwd = acp.str(params, "cwd") orelse a.cwd;
    // On an SSH host: the command runs there, through the shared connection.
    var where: []const u8 = cwd;
    if (a.remote) |r| {
        argv.clearRetainingCapacity();
        try argv.appendSlice(arena, &.{ "/bin/sh", "-c", try r.wrap(arena, label) });
        where = try std.fmt.allocPrint(arena, "{s}:{s}", .{ r.host, r.cwd });
        cwd = a.cwd;
    }

    var env: std.ArrayList([]const u8) = .empty;
    try env.appendSlice(arena, a.env);
    if (acp.obj(params, "env")) |vars| if (vars == .array) for (vars.array.items) |v| {
        try env.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ acp.str(v, "name") orelse continue, acp.str(v, "value") orelse "" }));
    };
    try env.append(arena, "PAGER=cat");
    try env.append(arena, "GIT_PAGER=cat");

    const b = a.app.newBlock(a.app.ctx, label, where) orelse return error.OutOfMemory;
    const t = try a.gpa.create(Terminal);
    errdefer a.gpa.destroy(t);
    t.* = .{
        .agent = a,
        .id = try std.fmt.allocPrint(a.gpa, "term-{d}", .{a.terminals.next}),
        .block = b,
        .output_limit = @intCast(@max(1024, acp.int(params, "outputByteLimit") orelse 1 << 20)),
    };
    a.terminals.next += 1;
    try proc.spawnPipes(&t.process, try proc.cStrings(arena, argv.items), try proc.cStrings(arena, env.items), try arena.dupeSentinel(u8, cwd, 0), true, .{
        .ctx = t,
        .output = terminalBytes,
        .exited = terminalExited,
    });
    try a.terminals.list.append(a.gpa, t);
    if (a.current()) |turn| a.addItem(turn, .{ .command = b });
    a.client.respond(id, .{ .terminalId = t.id });
}

fn terminalBytes(ctx: *anyopaque, bytes: []const u8) void {
    const t: *Terminal = @ptrCast(@alignCast(ctx));
    t.block.output.feed(bytes) catch {};
    t.agent.app.changed(t.agent.app.ctx);
}

fn terminalExited(ctx: *anyopaque, code: i32) void {
    const t: *Terminal = @ptrCast(@alignCast(ctx));
    t.block.finish(code);
    for (t.waiting.items) |w| {
        t.agent.client.respond(w, .{ .exitCode = code, .signal = null });
        t.agent.gpa.free(w);
    }
    t.waiting.clearRetainingCapacity();
    t.agent.app.changed(t.agent.app.ctx);
}

fn terminalOutput(a: *Agent, id: []const u8, t: *Terminal, arena: std.mem.Allocator) void {
    var all = t.block.output.plainText(arena) catch "";
    // Exactly what it printed: a final newline included.
    const lines = t.block.output.lines.items;
    if (lines.len > 1 and lines[lines.len - 1].text.items.len == 0) all = std.mem.concat(arena, u8, &.{ all, "\n" }) catch all;
    const truncated = all.len > t.output_limit;
    var out = if (truncated) all[all.len - t.output_limit ..] else all;
    // Never start in the middle of a UTF-8 sequence.
    while (out.len > 0 and (out[0] & 0xc0) == 0x80) out = out[1..];
    const Exit = struct { exitCode: i32, signal: ?[]const u8 = null };
    const exit: ?Exit = if (t.process.exit_code) |c| .{ .exitCode = c } else null;
    a.client.respond(id, .{ .output = out, .truncated = truncated, .exitStatus = exit });
}
