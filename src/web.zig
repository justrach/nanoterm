//! Requests over HTTPS, as Jev makes them: curl, configured through its
//! input (so a key never shows in a process list), its answer read on the
//! main thread when it comes (`proc.zig`), and a callback with the status
//! and the body, or the file it wrote.
const std = @import("std");
const proc = @import("proc.zig");

pub const Done = struct {
    ctx: *anyopaque,
    /// curl's exit code (0: an answer in 2xx), and the body.
    func: *const fn (ctx: *anyopaque, code: i32, body: []const u8) void,
};

pub const Options = struct {
    method: []const u8 = "GET",
    url: []const u8,
    bearer: ?[]const u8 = null,
    /// A JSON body.
    json: ?[]const u8 = null,
    /// Writes the body to this file instead (a picture).
    output: ?[]const u8 = null,
    max_seconds: u32 = 20,
    max_bytes: u32 = 16 * 1024 * 1024,
};

pub const Call = struct {
    gpa: std.mem.Allocator,
    process: proc.Process = undefined,
    running: bool = false,
    body: std.ArrayList(u8) = .empty,
    done: ?Done = null,

    pub fn deinit(call: *Call) void {
        if (call.running) call.process.close();
        call.running = false;
        call.body.deinit(call.gpa);
    }

    /// Starts the request; `done` is called once it ends (not if this fails).
    pub fn start(call: *Call, o: Options, done: Done) !void {
        if (call.running) return error.Busy;
        var arena_state: std.heap.ArenaAllocator = .init(call.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var config: std.ArrayList(u8) = .empty;
        try quoted(arena, &config, "url", o.url);
        try quoted(arena, &config, "request", o.method);
        if (o.bearer) |key| try quoted(arena, &config, "header", try std.fmt.allocPrint(arena, "Authorization: Bearer {s}", .{key}));
        if (o.json) |body| {
            try quoted(arena, &config, "header", "Content-Type: application/json");
            try quoted(arena, &config, "data-binary", body);
        }
        if (o.output) |path| try quoted(arena, &config, "output", path);
        try config.print(arena, "silent\nfail\nlocation\nproto = \"=https,http\"\nmax-time = {d}\nmax-filesize = {d}\n", .{ o.max_seconds, o.max_bytes });
        call.body.clearRetainingCapacity();
        call.done = done;
        try proc.spawnPipes(&call.process, try proc.cStrings(arena, &.{ "/usr/bin/curl", "-K", "-" }), try proc.cStrings(arena, &.{"PATH=/usr/bin:/bin"}), null, false, .{ .ctx = call, .output = onOutput, .exited = onExit });
        call.running = true;
        call.process.send(config.items);
        call.process.closeInput();
    }

    fn onOutput(ctx: *anyopaque, bytes: []const u8) void {
        const call: *Call = @ptrCast(@alignCast(ctx));
        if (call.body.items.len < 1 << 20) call.body.appendSlice(call.gpa, bytes) catch {};
    }

    fn onExit(ctx: *anyopaque, code: i32) void {
        const call: *Call = @ptrCast(@alignCast(ctx));
        call.process.close();
        call.running = false;
        if (call.done) |d| d.func(d.ctx, code, call.body.items);
    }
};

/// `name = "value"`, the value escaped as curl's configuration reads it.
fn quoted(arena: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try out.print(arena, "{s} = \"", .{name});
    for (value) |ch| switch (ch) {
        '\\' => try out.appendSlice(arena, "\\\\"),
        '"' => try out.appendSlice(arena, "\\\""),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        else => try out.append(arena, ch),
    };
    try out.appendSlice(arena, "\"\n");
}

test "curl's configuration escapes what it quotes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.ArrayList(u8) = .empty;
    try quoted(arena.allocator(), &out, "data-binary", "{\"a\":\"b\\\\c\"}\n");
    try std.testing.expectEqualStrings("data-binary = \"{\\\"a\\\":\\\"b\\\\\\\\c\\\"}\\n\"\n", out.items);
}
