//! Anonymous usage analytics, only when the user said yes (in onboarding
//! or Settings), under Standard Harness's privacy policy. An event says
//! what happened (the app opened, onboarding finished, a prompt went to an
//! agent), with the app's version, the OS, the CPU and the install's random
//! id; never commands, prompts, files, paths or output. Events go one at a
//! time, in the background; one that fails is dropped, never retried.
const std = @import("std");
const builtin = @import("builtin");
const web = @import("web.zig");
const settings = @import("settings.zig");

pub const default_endpoint = "https://standardharness.com/api/events";
pub const privacy_url = "https://standardharness.com/privacy";
pub const terms_url = "https://standardharness.com/terms";

/// Events kept while one is being sent; past this, new ones are dropped.
const max_queue = 32;

pub const Client = struct {
    gpa: std.mem.Allocator,
    /// `NANOTERM_ANALYTICS_URL` points elsewhere (a test's).
    endpoint: []const u8 = default_endpoint,
    version: []const u8 = "dev",
    call: web.Call,
    queue: std.ArrayList([]u8) = .empty,
    /// Events sent (and failed), for tests.
    sent: usize = 0,

    pub fn init(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) Client {
        var c: Client = .{ .gpa = gpa, .call = .{ .gpa = gpa } };
        if (env.get("NANOTERM_ANALYTICS_URL")) |u| if (u.len > 0) {
            c.endpoint = u;
        };
        return c;
    }

    pub fn deinit(c: *Client) void {
        c.call.deinit();
        for (c.queue.items) |e| c.gpa.free(e);
        c.queue.deinit(c.gpa);
    }

    /// Records `event` with `props` (a struct of plain values), if the user
    /// shares analytics.
    pub fn track(c: *Client, prefs: *const settings.Prefs, event: []const u8, props: anytype) void {
        if (prefs.analytics != .on) return;
        if (c.queue.items.len >= max_queue) return;
        const body = payload(c.gpa, c.version, &prefs.install_id, event, props) catch return;
        c.queue.append(c.gpa, body) catch {
            c.gpa.free(body);
            return;
        };
        c.next();
    }

    fn next(c: *Client) void {
        if (c.call.running or c.queue.items.len == 0) return;
        c.call.start(.{ .method = "POST", .url = c.endpoint, .json = c.queue.items[0], .max_seconds = 10 }, .{ .ctx = c, .func = done }) catch {
            c.gpa.free(c.queue.orderedRemove(0));
        };
    }

    fn done(ctx: *anyopaque, _: i32, _: []const u8) void {
        const c: *Client = @ptrCast(@alignCast(ctx));
        c.gpa.free(c.queue.orderedRemove(0));
        c.sent += 1;
        c.next();
    }
};

/// One event as JSON: no more than this, by design.
pub fn payload(gpa: std.mem.Allocator, version: []const u8, install_id: []const u8, event: []const u8, props: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{
        .app = "nanoterm",
        .version = version,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .install_id = install_id,
        .event = event,
        .props = props,
    }, .{});
}

test "an event is what it says and no more; nothing without consent" {
    const gpa = std.testing.allocator;
    const body = try payload(gpa, "0.1.14", "abc", "agent_prompt", .{ .agent = "graff" });
    defer gpa.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"event\":\"agent_prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"props\":{\"agent\":\"graff\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"install_id\":\"abc\"") != null);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(arena.allocator());
    var prefs: settings.Prefs = .init(gpa, std.testing.io, arena.allocator(), "/tmp/nanoterm-test-analytics-none", &env);
    defer prefs.deinit();
    var c: Client = .init(gpa, &env);
    defer c.deinit();
    c.track(&prefs, "app_open", .{});
    try std.testing.expectEqual(@as(usize, 0), c.queue.items.len);
    try std.testing.expect(!c.call.running);
}
