//! What Settings (⌘,) keeps: the agent new tabs start with, the text
//! size, the input's editing keys, whether onboarding was done, and the
//! analytics choice (with the install's random id, sent only with it), in
//! `~/Library/Application Support/nanoterm/settings.json`; the
//! Codegraff account (graff's own credential file); and which agents are
//! installed, looked for when Settings opens.
const std = @import("std");
const agent_mod = @import("agent.zig");
const Which = agent_mod.Which;
const codegraff = @import("codegraff.zig");
const launch = @import("agent_launch.zig");

/// Whether anonymous usage analytics are shared: not asked yet, yes, no.
pub const Analytics = enum { unset, on, off };

pub const Prefs = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8 = "",
    agent: Which = .graff,
    zoom: f32 = 1,
    keys: @import("nanoui").ui.Keymap = .system,
    onboarded: bool = false,
    analytics: Analytics = .unset,
    install_id: [32]u8 = @splat('0'),
    account: codegraff.Account,
    installed: std.EnumArray(Which, bool) = .initFill(false),
    /// Anonymous usage analytics, sent only when `analytics` is on.
    telemetry: @import("analytics.zig").Client,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, home: []const u8, env: *std.process.Environ.Map) Prefs {
        var p: Prefs = .{ .gpa = gpa, .io = io, .account = .init(gpa, io, home, env), .telemetry = .init(gpa, env) };
        p.path = std.fs.path.join(arena, &.{ home, "Library", "Application Support", "nanoterm", "settings.json" }) catch "";
        const data = std.Io.Dir.cwd().readFileAlloc(io, p.path, gpa, .limited(64 * 1024)) catch return p;
        defer gpa.free(data);
        const S = struct { agent: []const u8 = "graff", zoom: f32 = 1, keys: []const u8 = "system", onboarded: bool = false, analytics: []const u8 = "unset", install_id: []const u8 = "" };
        const parsed = std.json.parseFromSlice(S, gpa, data, .{ .ignore_unknown_fields = true }) catch return p;
        defer parsed.deinit();
        const v = parsed.value;
        p.agent = std.meta.stringToEnum(Which, v.agent) orelse .graff;
        p.zoom = std.math.clamp(v.zoom, 0.6, 2.4);
        p.keys = std.meta.stringToEnum(@TypeOf(p.keys), v.keys) orelse .system;
        p.onboarded = v.onboarded;
        p.analytics = std.meta.stringToEnum(Analytics, v.analytics) orelse .unset;
        if (v.install_id.len == p.install_id.len) @memcpy(&p.install_id, v.install_id);
        return p;
    }

    pub fn deinit(p: *Prefs) void {
        p.account.deinit();
        p.telemetry.deinit();
    }

    /// Records an anonymous usage event, if the user shares analytics.
    pub fn track(p: *Prefs, event: []const u8, props: anytype) void {
        p.telemetry.track(p, event, props);
    }

    fn save(p: *Prefs) void {
        if (p.path.len == 0) return;
        if (std.fs.path.dirname(p.path)) |dir| std.Io.Dir.cwd().createDirPath(p.io, dir) catch {};
        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\n  \"agent\": \"{s}\",\n  \"zoom\": {d:.2},\n  \"keys\": \"{s}\",\n  \"onboarded\": {},\n  \"analytics\": \"{s}\",\n  \"install_id\": \"{s}\"\n}}\n", .{ @tagName(p.agent), p.zoom, @tagName(p.keys), p.onboarded, @tagName(p.analytics), &p.install_id }) catch return;
        std.Io.Dir.cwd().writeFile(p.io, .{ .sub_path = p.path, .data = json }) catch {};
    }

    /// The agent new tabs start with.
    pub fn setAgent(p: *Prefs, w: Which) void {
        if (p.agent == w) return;
        p.agent = w;
        p.save();
    }

    pub fn setKeys(p: *Prefs, k: @TypeOf(@as(Prefs, undefined).keys)) void {
        if (p.keys == k) return;
        p.keys = k;
        p.save();
    }

    /// Onboarding is done (shown once).
    pub fn finishOnboarding(p: *Prefs) void {
        p.onboarded = true;
        p.save();
    }

    /// Shares anonymous usage analytics, or stops; a new random id the
    /// first time they're turned on.
    pub fn setAnalytics(p: *Prefs, a: Analytics, io: std.Io) void {
        if (a == .on and std.mem.allEqual(u8, &p.install_id, '0')) {
            var raw: [16]u8 = undefined;
            io.random(&raw);
            p.install_id = std.fmt.bytesToHex(raw, .lower);
        }
        p.analytics = a;
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
        p.setKeys(.vim);
        p.setAnalytics(.on, io);
        p.finishOnboarding();
    }
    var p: Prefs = .init(gpa, io, arena.allocator(), home, &env);
    defer p.deinit();
    try std.testing.expectEqual(Which.codex, p.agent);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), p.zoom, 0.001);
    try std.testing.expectEqual(@import("nanoui").ui.Keymap.vim, p.keys);
    try std.testing.expect(p.onboarded);
    try std.testing.expectEqual(Analytics.on, p.analytics);
    try std.testing.expect(!std.mem.allEqual(u8, &p.install_id, '0'));
}
