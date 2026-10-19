//! "Sign in with Codegraff", as Harness and `graff login` sign in: the
//! gateway's device flow (`POST /v1/device/start`, approval in the browser
//! at codegraff.com, `POST /v1/device/poll` until it hands back a `cg_sk_`
//! key once). The key goes in graff's own credential file,
//! `~/.simple-harness-codegraff.json` (0600), so signing in here signs graff
//! in, `graff login` signs nanoterm in, and signing out here (which revokes
//! the key) signs both out. The account's email and credits are asked of
//! `/v1/me` and `/v1/usage/summary`, and only shown.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const web = @import("web.zig");

pub const default_gateway = "https://gateway.codegraff.com";
pub const key_file = ".simple-harness-codegraff.json";

pub const State = enum { signed_out, starting, waiting, signed_in };

pub const Account = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    /// `NANOTERM_CODEGRAFF_GATEWAY` points at another (a test's).
    gateway: []const u8 = default_gateway,
    state: State = .signed_out,
    key: ?[]u8 = null,
    email: ?[]u8 = null,
    tier: ?[]u8 = null,
    credits_micro_usd: ?i64 = null,
    /// The last attempt's failure, shown until the next.
    failure: ?[]const u8 = null,
    /// The approval page and its code, while waiting for it.
    url: ?[]u8 = null,
    code: ?[]u8 = null,
    device_code: ?[]u8 = null,
    interval_ms: u64 = 2000,
    deadline_ms: i64 = 0,
    /// Bumped by a cancel: a poll of an older attempt does nothing.
    attempt: u32 = 0,
    call: web.Call,
    lookup: web.Call,
    /// Opens the approval page (the browser; a test records it).
    open: *const fn (url: []const u8) void = openInBrowser,
    /// Something shown changed; and the key did (Jev's).
    changed: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque) void } = null,
    key_changed: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque, ?[]const u8) void } = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, home: []const u8, env: *const std.process.Environ.Map) Account {
        var a: Account = .{ .gpa = gpa, .io = io, .home = home, .call = .{ .gpa = gpa }, .lookup = .{ .gpa = gpa } };
        if (env.get("NANOTERM_CODEGRAFF_GATEWAY")) |g| if (g.len > 0) {
            a.gateway = std.mem.trimEnd(u8, g, "/");
        };
        return a;
    }

    pub fn deinit(a: *Account) void {
        a.call.deinit();
        a.lookup.deinit();
        for ([_]?[]u8{ a.key, a.email, a.tier, a.url, a.code, a.device_code }) |s| if (s) |x| a.gpa.free(x);
    }

    fn set(a: *Account, field: *?[]u8, value: ?[]const u8) void {
        if (field.*) |old| a.gpa.free(old);
        field.* = if (value) |v| a.gpa.dupe(u8, v) catch null else null;
    }

    fn notify(a: *Account) void {
        if (a.changed) |c| c.func(c.ctx);
    }

    fn path(a: *Account, buf: []u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ a.home, key_file }) catch null;
    }

    /// Signed in already (graff's file has a key): who, and their credits.
    pub fn load(a: *Account) void {
        var buf: [1024]u8 = undefined;
        const p = a.path(&buf) orelse return;
        const data = std.Io.Dir.cwd().readFileAlloc(a.io, p, a.gpa, .limited(64 * 1024)) catch return;
        defer a.gpa.free(data);
        const parsed = std.json.parseFromSlice(struct { api_key: []const u8 = "" }, a.gpa, data, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        if (parsed.value.api_key.len == 0) return;
        a.set(&a.key, parsed.value.api_key);
        a.state = .signed_in;
        a.fetchMe();
    }

    /// Starts signing in: the approval page opens in the browser.
    pub fn signIn(a: *Account) void {
        if (a.state == .starting or a.state == .waiting) return;
        a.failure = null;
        a.state = .starting;
        a.attempt +%= 1;
        const url = std.fmt.allocPrint(a.gpa, "{s}/v1/device/start", .{a.gateway}) catch return a.fail("Out of memory.");
        defer a.gpa.free(url);
        a.call.start(.{ .method = "POST", .url = url, .json = "{\"device_label\":\"nanoterm\"}" }, .{ .ctx = a, .func = onStart }) catch return a.fail("Couldn't reach Codegraff.");
        a.notify();
    }

    /// Stops waiting for the browser.
    pub fn cancel(a: *Account) void {
        if (a.state != .starting and a.state != .waiting) return;
        a.attempt +%= 1;
        a.state = if (a.key != null) .signed_in else .signed_out;
        a.notify();
    }

    /// Signs out here and in graff: the key is revoked, then removed.
    pub fn signOut(a: *Account) void {
        if (a.key) |key| {
            const url = std.fmt.allocPrint(a.gpa, "{s}/v1/keys/revoke", .{a.gateway}) catch null;
            if (url) |u| {
                defer a.gpa.free(u);
                // Removed here whether or not the revoke gets through.
                a.lookup.deinit();
                a.lookup = .{ .gpa = a.gpa };
                a.lookup.start(.{ .method = "POST", .url = u, .bearer = key, .max_seconds = 5 }, .{ .ctx = a, .func = ignore }) catch {};
            }
        }
        var buf: [1024]u8 = undefined;
        if (a.path(&buf)) |p| std.Io.Dir.cwd().deleteFile(a.io, p) catch {};
        a.set(&a.key, null);
        a.set(&a.email, null);
        a.set(&a.tier, null);
        a.credits_micro_usd = null;
        a.state = .signed_out;
        a.attempt +%= 1;
        if (a.key_changed) |k| k.func(k.ctx, null);
        a.notify();
    }

    fn ignore(_: *anyopaque, _: i32, _: []const u8) void {}

    fn fail(a: *Account, why: []const u8) void {
        a.failure = why;
        a.state = if (a.key != null) .signed_in else .signed_out;
        a.notify();
    }

    fn onStart(ctx: *anyopaque, code: i32, body: []const u8) void {
        const a: *Account = @ptrCast(@alignCast(ctx));
        if (a.state != .starting) return;
        if (code != 0) return a.fail("Couldn't reach Codegraff. Check your connection and try again.");
        const S = struct { device_code: []const u8, user_code: []const u8 = "", verification_uri: []const u8, verification_uri_complete: ?[]const u8 = null, expires_in: i64 = 600, interval: u64 = 2 };
        const parsed = std.json.parseFromSlice(S, a.gpa, body, .{ .ignore_unknown_fields = true }) catch return a.fail("Codegraff answered something unexpected.");
        defer parsed.deinit();
        const v = parsed.value;
        a.set(&a.device_code, v.device_code);
        a.set(&a.code, v.user_code);
        a.set(&a.url, v.verification_uri_complete orelse v.verification_uri);
        a.interval_ms = std.math.clamp(v.interval, 1, 30) * 1000;
        a.deadline_ms = nowMs() + @max(v.expires_in, 1) * 1000;
        a.state = .waiting;
        if (a.url) |u| a.open(u);
        a.schedule();
        a.notify();
    }

    fn schedule(a: *Account) void {
        const Tick = struct {
            account: *Account,
            attempt: u32,
            fn run(ctx: ?*anyopaque) callconv(.c) void {
                const t: *@This() = @ptrCast(@alignCast(ctx));
                defer t.account.gpa.destroy(t);
                if (t.attempt == t.account.attempt) t.account.poll();
            }
        };
        const t = a.gpa.create(Tick) catch return;
        t.* = .{ .account = a, .attempt = a.attempt };
        nanoui.App.after(a.interval_ms, t, Tick.run);
    }

    fn poll(a: *Account) void {
        if (a.state != .waiting) return;
        if (nowMs() >= a.deadline_ms) return a.fail("The sign-in link expired. Try again.");
        const url = std.fmt.allocPrint(a.gpa, "{s}/v1/device/poll", .{a.gateway}) catch return;
        defer a.gpa.free(url);
        const body = std.fmt.allocPrint(a.gpa, "{{\"device_code\":{f}}}", .{std.json.fmt(a.device_code orelse "", .{})}) catch return;
        defer a.gpa.free(body);
        a.call.start(.{ .method = "POST", .url = url, .json = body, .max_seconds = 10 }, .{ .ctx = a, .func = onPoll }) catch a.schedule();
    }

    fn onPoll(ctx: *anyopaque, code: i32, body: []const u8) void {
        const a: *Account = @ptrCast(@alignCast(ctx));
        if (a.state != .waiting) return;
        // Trouble reaching it: keep polling, as `graff login` does.
        if (code != 0) return a.schedule();
        const P = struct { status: []const u8 = "", api_key: ?[]const u8 = null, email: ?[]const u8 = null, interval: ?u64 = null };
        const parsed = std.json.parseFromSlice(P, a.gpa, body, .{ .ignore_unknown_fields = true }) catch return a.schedule();
        defer parsed.deinit();
        const v = parsed.value;
        const eq = std.mem.eql;
        if (eq(u8, v.status, "pending")) {
            if (v.interval) |i| a.interval_ms = std.math.clamp(i, 1, 30) * 1000;
            return a.schedule();
        }
        if (eq(u8, v.status, "ok")) {
            const key = v.api_key orelse return a.fail("Codegraff approved without a key.");
            a.finish(key, v.email) catch return a.fail("Couldn't save the Codegraff key.");
            return;
        }
        a.fail(if (eq(u8, v.status, "denied")) "Sign-in was denied in the browser." else if (eq(u8, v.status, "expired")) "The sign-in link expired. Try again." else if (eq(u8, v.status, "consumed")) "This sign-in was already used. Try again." else "Codegraff lost this sign-in. Try again.");
    }

    /// The key, in graff's file (only this user may read it).
    fn finish(a: *Account, key: []const u8, email: ?[]const u8) !void {
        var buf: [1024]u8 = undefined;
        const p = a.path(&buf) orelse return error.NoHome;
        const json = try std.fmt.allocPrint(a.gpa, "{{\n  \"api_key\": {f}\n}}\n", .{std.json.fmt(key, .{})});
        defer a.gpa.free(json);
        const perms: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
        try std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = p, .data = json, .flags = .{ .permissions = perms } });
        a.set(&a.key, key);
        if (email) |e| a.set(&a.email, e);
        a.state = .signed_in;
        a.failure = null;
        if (a.key_changed) |k| k.func(k.ctx, a.key);
        a.fetchMe();
        a.notify();
    }

    /// Who is signed in, and their credits, for Settings.
    fn fetchMe(a: *Account) void {
        const key = a.key orelse return;
        const url = std.fmt.allocPrint(a.gpa, "{s}/v1/usage/summary", .{a.gateway}) catch return;
        defer a.gpa.free(url);
        a.lookup.start(.{ .url = url, .bearer = key, .max_seconds = 10 }, .{ .ctx = a, .func = onMe }) catch {};
    }

    fn onMe(ctx: *anyopaque, code: i32, body: []const u8) void {
        const a: *Account = @ptrCast(@alignCast(ctx));
        if (code != 0 or a.key == null) return;
        const U = struct { email: ?[]const u8 = null, tier: ?[]const u8 = null, credits_micro_usd: ?i64 = null };
        const parsed = std.json.parseFromSlice(U, a.gpa, body, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        if (parsed.value.email) |e| a.set(&a.email, e);
        if (parsed.value.tier) |t| a.set(&a.tier, t);
        a.credits_micro_usd = parsed.value.credits_micro_usd;
        a.notify();
    }
};

fn nowMs() i64 {
    return @intFromFloat(@import("blocks.zig").now() * 1000);
}

fn openInBrowser(url: []const u8) void {
    _ = nanoui.shell.openUrl(url);
}
