//! graff's models, for the model picker: `graff models` lists its live
//! catalog by provider. It is read once, in the background, when the
//! picker first opens (it takes most of a second).
const std = @import("std");
const proc = @import("proc.zig");

pub const Model = struct {
    provider: []const u8,
    name: []const u8,
    /// Context window and price, as graff prints them.
    detail: []const u8,
};

pub const Catalog = struct {
    gpa: std.mem.Allocator,
    state: enum { idle, loading, ready, failed } = .idle,
    models: std.ArrayList(Model) = .empty,
    text: std.ArrayList(u8) = .empty,
    process: proc.Process = undefined,
    changed: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque) void } = null,

    pub fn deinit(c: *Catalog) void {
        if (c.state == .loading) c.process.close();
        c.models.deinit(c.gpa);
        c.text.deinit(c.gpa);
    }

    /// Starts `graff models` (once).
    pub fn load(c: *Catalog, arena: std.mem.Allocator, graff: []const u8, envp: [*:null]const ?[*:0]const u8) void {
        if (c.state != .idle) return;
        const argv = proc.cStrings(arena, &.{ graff, "models" }) catch return;
        proc.spawnPipes(&c.process, argv, envp, null, true, .{ .ctx = c, .output = onOutput, .exited = onExit }) catch {
            c.state = .failed;
            return;
        };
        c.process.closeInput();
        c.state = .loading;
    }

    fn onOutput(ctx: *anyopaque, bytes: []const u8) void {
        const c: *Catalog = @ptrCast(@alignCast(ctx));
        if (c.text.items.len < 1024 * 1024) c.text.appendSlice(c.gpa, bytes) catch {};
    }

    fn onExit(ctx: *anyopaque, code: i32) void {
        const c: *Catalog = @ptrCast(@alignCast(ctx));
        c.process.close();
        c.parse() catch {};
        c.state = if (code == 0 and c.models.items.len > 0) .ready else .failed;
        if (c.changed) |ch| ch.func(ch.ctx);
    }

    /// Reads "provider:" headers and "  model   200000 ctx   $1/2 per 1M" lines.
    pub fn parse(c: *Catalog) !void {
        c.models.clearRetainingCapacity();
        var provider: []const u8 = "";
        var lines = std.mem.splitScalar(u8, c.text.items, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (line[0] != ' ') {
                provider = if (line[line.len - 1] == ':') line[0 .. line.len - 1] else "";
                continue;
            }
            if (provider.len == 0) continue;
            const t = std.mem.trim(u8, line, " ");
            const gap = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
            try c.models.append(c.gpa, .{
                .provider = provider,
                .name = t[0..gap],
                .detail = std.mem.trim(u8, t[gap..], " "),
            });
        }
    }
};

test "graff's catalog" {
    var c: Catalog = .{ .gpa = std.testing.allocator };
    defer c.deinit();
    try c.text.appendSlice(c.gpa, "model catalog — 3 entries\n\nanthropic:\n  claude-opus-5-5     1000000 ctx   $4/20 per 1M\n  claude-haiku-5-5   1000000 ctx   $0.1/0.5 per 1M\n\nlmstudio:\n  lmstudio   200000 ctx   (unpriced)\n");
    try c.parse();
    try std.testing.expectEqual(@as(usize, 3), c.models.items.len);
    try std.testing.expectEqualStrings("anthropic", c.models.items[1].provider);
    try std.testing.expectEqualStrings("claude-haiku-5-5", c.models.items[1].name);
    try std.testing.expectEqualStrings("1000000 ctx   $0.1/0.5 per 1M", c.models.items[1].detail);
    try std.testing.expectEqualStrings("lmstudio", c.models.items[2].provider);
}
