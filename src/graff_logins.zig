//! graff's own provider sign-ins (ChatGPT, xAI, Kimi, Z.AI), as Harness's
//! accounts screen has them (its engine/src/graff_logins.rs).
//!
//! Signed in is graff's credential file being there: xAI, Kimi and Z.AI keep
//! one each, `~/.<id>/credentials/graff-oauth.json`. ChatGPT's plan sign-in
//! (`chatgpt-new`) is one record, `~/.graff/credentials/chatgpt-new.json`,
//! that outlives a sign-out, so it is signed in only while it holds a token
//! and ready only when that token was granted plan usage. Nothing here
//! refreshes a token, touches the network or keeps a token's value.
//!
//! A sign-in runs `graff login <id>` in the background: graff opens the
//! page itself and prints its link (and, for xAI and Kimi, a code to
//! confirm), which the row shows. `graff login` exits 0 even when it
//! refuses, so a sign-in counts only when the credential changed or graff
//! printed its `✓` line (ChatGPT: and said plan usage is on). Signing out
//! removes the file; ChatGPT's goes through `graff logout chatgpt-new`,
//! which revokes the session and keeps the registration.
const std = @import("std");
const proc = @import("proc.zig");

pub const Provider = struct { id: []const u8, name: []const u8, lab: []const u8 };

pub const providers = [_]Provider{
    .{ .id = "chatgpt-new", .name = "ChatGPT", .lab = "openai" },
    .{ .id = "xai", .name = "xAI", .lab = "xai" },
    .{ .id = "kimi", .name = "Kimi", .lab = "moonshot" },
    .{ .id = "zai", .name = "Z.AI", .lab = "zai" },
};

/// The scope a ChatGPT sign-in needs before requests run on the plan.
pub const plan_scope = "chatgpt.tokens.use.direct";

pub fn credentialPath(arena: std.mem.Allocator, home: []const u8, id: []const u8) ![]const u8 {
    if (std.mem.eql(u8, id, "chatgpt-new")) return std.fs.path.join(arena, &.{ home, ".graff", "credentials", "chatgpt-new.json" });
    const dot = try std.fmt.allocPrint(arena, ".{s}", .{id});
    return std.fs.path.join(arena, &.{ home, dot, "credentials", "graff-oauth.json" });
}

pub const Status = struct {
    /// Ready to use (ChatGPT: signed in with plan usage).
    signed_in: bool = false,
    /// ChatGPT: the account, when the record names one (in the arena).
    account: []const u8 = "",
    /// ChatGPT: signed in, but plan usage wasn't granted.
    plan_off: bool = false,
};

/// What graff's ChatGPT record says, from its bytes.
pub fn chatgptStatus(arena: std.mem.Allocator, bytes: []const u8) Status {
    const Raw = struct { email: []const u8 = "", access_token: ?[]const u8 = null, scopes: []const []const u8 = &.{} };
    const raw = std.json.parseFromSliceLeaky(Raw, arena, bytes, .{ .ignore_unknown_fields = true }) catch return .{};
    const token = if (raw.access_token) |t| t.len > 0 else false;
    if (!token) return .{};
    var plan = false;
    for (raw.scopes) |s| plan = plan or std.mem.eql(u8, s, plan_scope);
    return .{ .signed_in = plan, .account = raw.email, .plan_off = !plan };
}

pub fn status(arena: std.mem.Allocator, io: std.Io, home: []const u8, id: []const u8) Status {
    const path = credentialPath(arena, home, id) catch return .{};
    if (std.mem.eql(u8, id, "chatgpt-new")) {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024)) catch return .{};
        return chatgptStatus(arena, bytes);
    }
    std.Io.Dir.cwd().access(io, path, .{}) catch return .{};
    return .{ .signed_in = true };
}

/// The credential file's modification time, to tell a fresh sign-in.
fn stamp(arena: std.mem.Allocator, io: std.Io, home: []const u8, id: []const u8) ?i96 {
    const path = credentialPath(arena, home, id) catch return null;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return st.mtime.nanoseconds;
}

// What `graff login` prints.

/// `line` without its color escapes (`ESC [ … letter`), in `buf`.
fn stripAnsi(buf: []u8, line: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < buf.len) : (i += 1) {
        if (line[i] == 0x1b) {
            // To the letter that ends it.
            i += 1;
            while (i < line.len and !std.ascii.isAlphabetic(line[i])) i += 1;
            continue;
        }
        buf[n] = line[i];
        n += 1;
    }
    return buf[0..n];
}

/// The sign-in page after "open this URL", once its line is complete.
pub fn scanUrl(out: []const u8) ?[]const u8 {
    var at: ?usize = null;
    for ([_][]const u8{ "open this URL", "Open this URL", "visit:", "Sign in with ChatGPT" }) |m| {
        if (std.mem.indexOf(u8, out, m)) |i| at = if (at) |a| @min(a, i) else i;
    }
    const after = out[at orelse return null ..];
    const start = std.mem.indexOf(u8, after, "https://") orelse return null;
    const rest = after[start..];
    const end = std.mem.indexOfAny(u8, rest, " \t\r\n") orelse return null;
    return rest[0..end];
}

/// The code to confirm on the page (xAI and Kimi print one).
pub fn scanCode(out: []const u8) ?[]const u8 {
    const marker = "confirm the code:";
    const i = std.mem.indexOf(u8, out, marker) orelse return null;
    const rest = out[i + marker.len ..];
    const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
    const code = std.mem.trim(u8, rest[0..nl], " \t\r");
    return if (code.len > 0) code else null;
}

/// graff's last `✗` line, or its last line, or a generic word.
pub fn failure(arena: std.mem.Allocator, out: []const u8) []const u8 {
    var last: []const u8 = "";
    var it = std.mem.splitBackwardsScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const buf = arena.alloc(u8, raw.len) catch continue;
        const l = std.mem.trim(u8, stripAnsi(buf, raw), " \t\r");
        if (l.len == 0) continue;
        if (std.mem.startsWith(u8, l, "✗")) return std.mem.trim(u8, l["✗".len..], " ");
        if (last.len == 0) last = l;
    }
    return if (last.len > 0) last else "The sign-in did not finish.";
}

fn anyLine(out: []const u8, comptime ok: fn ([]const u8) bool) bool {
    var buf: [1024]u8 = undefined;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| if (ok(std.mem.trim(u8, stripAnsi(&buf, raw[0..@min(raw.len, buf.len)]), " \t\r"))) return true;
    return false;
}

fn isSuccess(l: []const u8) bool {
    return std.mem.startsWith(u8, l, "✓");
}

fn isPlanGranted(l: []const u8) bool {
    return std.mem.startsWith(u8, l, "✓ signed in to ChatGPT as ") and std.mem.indexOf(u8, l, "; plan usage is on.") != null;
}

fn isPlanDenied(l: []const u8) bool {
    return std.mem.startsWith(u8, l, "✓ signed in to ChatGPT as ") and std.mem.indexOf(u8, l, "plan usage was not allowed") != null;
}

pub const plan_off_message = "Signed in to ChatGPT, but plan usage is off. Continue with ChatGPT again and allow plan usage.";

/// One sign-in (or ChatGPT's sign-out) under way.
pub const Flow = struct {
    id: []const u8,
    signing_out: bool = false,
    process: proc.Process = undefined,
    output: std.ArrayList(u8) = .empty,
    before: ?i96 = null,
};

/// The sign-ins: one flow at a time, its result, and how to redraw.
pub const Logins = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// Where graff keeps its sign-ins: the HOME it runs with.
    home: []const u8,
    flow: ?*Flow = null,
    /// The last flow's failure, for its provider's row.
    failed_id: []const u8 = "",
    failed: std.ArrayList(u8) = .empty,
    changed: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque) void } = null,

    pub fn deinit(l: *Logins) void {
        l.drop();
        l.failed.deinit(l.gpa);
    }

    fn redraw(l: *Logins) void {
        if (l.changed) |ch| ch.func(ch.ctx);
    }

    fn drop(l: *Logins) void {
        const f = l.flow orelse return;
        f.process.close();
        f.output.deinit(l.gpa);
        l.gpa.destroy(f);
        l.flow = null;
    }

    /// Starts `graff login <id>` (`graff` its path), cancelling one under way.
    pub fn start(l: *Logins, graff: []const u8, env_list: []const []const u8, id: []const u8) !void {
        try l.run(graff, env_list, id, "login");
    }

    fn run(l: *Logins, graff: []const u8, env_list: []const []const u8, id: []const u8, verb: []const u8) !void {
        l.drop();
        l.failed.clearRetainingCapacity();
        var arena: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const f = try l.gpa.create(Flow);
        f.* = .{ .id = id, .signing_out = std.mem.eql(u8, verb, "logout"), .before = stamp(a, l.io, l.home, id) };
        errdefer l.gpa.destroy(f);
        const argv = try proc.cStrings(a, &.{ graff, verb, id });
        try proc.spawnPipes(&f.process, argv, try proc.cStrings(a, env_list), null, true, .{ .ctx = l, .output = onOutput, .exited = onExit });
        l.flow = f;
        l.redraw();
    }

    pub fn cancel(l: *Logins) void {
        l.drop();
        l.redraw();
    }

    fn onOutput(ctx: *anyopaque, bytes: []const u8) void {
        const l: *Logins = @ptrCast(@alignCast(ctx));
        const f = l.flow orelse return;
        f.output.appendSlice(l.gpa, bytes) catch {};
        l.redraw();
    }

    fn onExit(ctx: *anyopaque, code: i32) void {
        const l: *Logins = @ptrCast(@alignCast(ctx));
        const f = l.flow orelse return;
        l.finish(f, code);
    }

    /// The flow ended: it landed, or its failure is kept for the row.
    fn finish(l: *Logins, f: *Flow, code: i32) void {
        var arena: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const out = f.output.items;
        if (f.signing_out) {
            l.drop();
            return l.redraw();
        }
        const now = stamp(a, l.io, l.home, f.id);
        const changed_file = now != null and now != f.before;
        const chatgpt = std.mem.eql(u8, f.id, "chatgpt-new");
        const landed = code == 0 and if (chatgpt) changed_file and anyLine(out, isPlanGranted) else changed_file or anyLine(out, isSuccess);
        if (!landed) {
            l.failed_id = f.id;
            l.failed.clearRetainingCapacity();
            const why = if (chatgpt and anyLine(out, isPlanDenied)) plan_off_message else failure(a, out);
            l.failed.appendSlice(l.gpa, why) catch {};
        }
        l.drop();
        l.redraw();
    }

    /// Signs out: removes the credential file; ChatGPT through
    /// `graff logout chatgpt-new` (in the background: it revokes the session).
    pub fn signOut(l: *Logins, graff: ?[]const u8, env_list: []const []const u8, id: []const u8) void {
        if (std.mem.eql(u8, id, "chatgpt-new")) {
            l.run(graff orelse return, env_list, id, "logout") catch {};
            return;
        }
        var arena: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena.deinit();
        const path = credentialPath(arena.allocator(), l.home, id) catch return;
        std.Io.Dir.cwd().deleteFile(l.io, path) catch {};
        l.redraw();
    }
};

// Verbatim from `graff login xai` / `kimi` / `zai` and `chatgpt-new`, as
// Harness's tests have them.
const xai_out = "\nTo log in to Grok (xAI), open this URL (browser should open automatically):\n\n  https://accounts.x.ai/device?user_code=ABCD-1234\n\nand confirm the code:  ABCD-1234\n\nwaiting for authorization…\n";
const zai_out = "\nTo log in to Z.AI Coding Plan, open this URL (browser should open automatically):\n\n  https://chat.z.ai/cli/authorize?flow=f1\n\nwaiting for authorization…\n";

test "graff login's link, code, success and failure, as Harness reads them" {
    try std.testing.expectEqualStrings("https://accounts.x.ai/device?user_code=ABCD-1234", scanUrl(xai_out).?);
    try std.testing.expectEqualStrings("ABCD-1234", scanCode(xai_out).?);
    try std.testing.expectEqualStrings("https://chat.z.ai/cli/authorize?flow=f1", scanUrl(zai_out).?);
    try std.testing.expect(scanCode(zai_out) == null);
    // A URL still being written is not one yet.
    try std.testing.expect(scanUrl("open this URL\n  https://accounts.x.ai/dev") == null);
    try std.testing.expect(anyLine("waiting…\n\x1b[32m✓\x1b[0m logged in to xAI\n", isSuccess));
    try std.testing.expect(anyLine("✓ signed in to ChatGPT as a@b.c; plan usage is on.\n", isPlanGranted));
    try std.testing.expect(anyLine("✓ signed in to ChatGPT as a@b.c, but plan usage was not allowed.\n", isPlanDenied));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("authorization denied", failure(arena.allocator(), "waiting…\n✗ authorization denied\n"));
}

test "ChatGPT's record: signed in only with a token, ready only with plan usage" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ready = chatgptStatus(a, "{\"email\":\"a@b.c\",\"client_id\":\"x\",\"access_token\":\"t\",\"scopes\":[\"openid\",\"chatgpt.tokens.use.direct\"]}");
    try std.testing.expect(ready.signed_in and !ready.plan_off);
    try std.testing.expectEqualStrings("a@b.c", ready.account);
    const off = chatgptStatus(a, "{\"email\":\"a@b.c\",\"access_token\":\"t\",\"scopes\":[\"openid\"]}");
    try std.testing.expect(!off.signed_in and off.plan_off);
    const out = chatgptStatus(a, "{\"email\":\"a@b.c\",\"client_id\":\"x\",\"access_token\":null}");
    try std.testing.expect(!out.signed_in and !out.plan_off);
}
