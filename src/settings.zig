//! What Settings (⌘,) keeps: the agent new tabs start with and the text
//! size, in `~/Library/Application Support/nanoterm/settings.json`; the
//! Codegraff account (graff's own credential file); and which agents are
//! installed, looked for when Settings opens.
const std = @import("std");
const agent_mod = @import("agent.zig");
const Which = agent_mod.Which;
const codegraff = @import("codegraff.zig");
const launch = @import("agent_launch.zig");

pub const Prefs = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8 = "",
    agent: Which = .graff,
    zoom: f32 = 1,
    account: codegraff.Account,
    installed: std.EnumArray(Which, bool) = .initFill(false),

    pub fn init(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, home: []const u8, env: *std.process.Environ.Map) Prefs {
        var p: Prefs = .{ .gpa = gpa, .io = io, .account = .init(gpa, io, home, env) };
        p.path = std.fs.path.join(arena, &.{ home, "Library", "Application Support", "nanoterm", "settings.json" }) catch "";
        const data = std.Io.Dir.cwd().readFileAlloc(io, p.path, gpa, .limited(64 * 1024)) catch return p;
        defer gpa.free(data);
        const parsed = std.json.parseFromSlice(struct { agent: []const u8 = "graff", zoom: f32 = 1 }, gpa, data, .{ .ignore_unknown_fields = true }) catch return p;
        defer parsed.deinit();
        p.agent = std.meta.stringToEnum(Which, parsed.value.agent) orelse .graff;
        p.zoom = std.math.clamp(parsed.value.zoom, 0.6, 2.4);
        return p;
    }

    pub fn deinit(p: *Prefs) void {
        p.account.deinit();
    }

    fn save(p: *Prefs) void {
        if (p.path.len == 0) return;
        if (std.fs.path.dirname(p.path)) |dir| std.Io.Dir.cwd().createDirPath(p.io, dir) catch {};
        var buf: [256]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\n  \"agent\": \"{s}\",\n  \"zoom\": {d:.2}\n}}\n", .{ @tagName(p.agent), p.zoom }) catch return;
        std.Io.Dir.cwd().writeFile(p.io, .{ .sub_path = p.path, .data = json }) catch {};
    }

    /// The agent new tabs start with.
    pub fn setAgent(p: *Prefs, w: Which) void {
        if (p.agent == w) return;
        p.agent = w;
        p.save();
    }

    pub fn setZoom(p: *Prefs, z: f32) void {
        if (@abs(p.zoom - z) < 0.001) return;
        p.zoom = z;
        p.save();
    }

    /// Looks again for each agent's CLI.
    pub fn refresh(p: *Prefs, env: *std.process.Environ.Map) void {
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        for (std.enums.values(Which)) |w| p.installed.set(w, launch.installed(arena.allocator(), p.io, env, w));
    }
};

test "settings are kept across launches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const home = "/tmp/nanoterm-test-settings";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var env: std.process.Environ.Map = .init(arena.allocator());
    {
        var p: Prefs = .init(gpa, io, arena.allocator(), home, &env);
        defer p.deinit();
        try std.testing.expectEqual(Which.graff, p.agent);
        p.setAgent(.codex);
        p.setZoom(1.2);
    }
    var p: Prefs = .init(gpa, io, arena.allocator(), home, &env);
    defer p.deinit();
    try std.testing.expectEqual(Which.codex, p.agent);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), p.zoom, 0.001);
}
