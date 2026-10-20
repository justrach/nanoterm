//! graff kept current, as Harness keeps its own (graff_bundle.rs). nanoterm
//! keeps a copy of graff, `~/Library/Application Support/nanoterm/bin/graff`,
//! and replaces it from codegraff's latest stable GitHub release: 30 s after
//! launch, then hourly, and when a graff session starts (at most every ten
//! minutes). The download is checked against the release's SHA256SUMS and
//! run once (`--version`) before it takes the copy's place by a rename, so
//! a running `graff acp` keeps the file it started from. Sessions run the
//! newest graff there is (`resolve`): on PATH, where installers put it, or
//! this copy; nothing is downloaded while one is already as new as the
//! release. A new one is announced on a card with its release lines.
//!
//! `GRAFF_EXECUTABLE` runs a graff of the user's own and turns this off, as
//! `NANOTERM_GRAFF_AUTO_UPDATE=0` does. Not on Windows yet.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const newer = nanoui.update.newer;

pub const latest_url = "https://api.github.com/repos/justrach/codegraff/releases/latest";
pub const downloads = "https://github.com/justrach/codegraff/releases/download";
const first_ms = 30 * 1000;
const every_ms = 60 * 60 * 1000;
const debounce_s = 10 * 60;
/// The most a release's archive may be.
const max_archive = 256 << 20;

/// The updater the app runs (none in tests that don't make one).
pub var global: ?*Updater = null;

/// graff updated: from what sessions ran, to the release, and the new
/// graff's own lines for it.
pub const Notice = struct { from: []const u8, to: []const u8, lines: []const []const u8 };

pub const Updater = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// nanoterm's copy, and where else graff is looked for.
    managed: []const u8,
    search: []const u8,
    latest: []const u8 = latest_url,
    downloads: []const u8 = downloads,
    busy: std.atomic.Value(bool) = .init(false),
    last_check: f64 = -std.math.inf(f64),
    /// The last update made, until "Got it"; in its own arena.
    notice: ?Notice = null,
    notice_arena: ?std.heap.ArenaAllocator = null,
    /// Called on the main thread when a notice comes.
    changed: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque) void } = null,

    /// An updater for this user, or null where graff is the user's own to
    /// keep (`GRAFF_EXECUTABLE`), updates are off, or on Windows.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, search: []const u8) !?*Updater {
        if (builtin.os.tag == .windows or assetName() == null) return null;
        if (env.get("GRAFF_EXECUTABLE")) |v| if (v.len > 0) return null;
        if (env.get("NANOTERM_GRAFF_AUTO_UPDATE")) |v| if (off(v)) return null;
        const home = env.get("HOME") orelse return null;
        const u = try gpa.create(Updater);
        errdefer gpa.destroy(u);
        u.* = .{ .gpa = gpa, .io = io, .managed = try managedPath(gpa, home), .search = try gpa.dupe(u8, search) };
        // A feed of the same files in a folder, for tests.
        if (env.get("NANOTERM_GRAFF_FEED")) |f| if (f.len > 0) {
            u.latest = try std.fmt.allocPrint(gpa, "{s}/latest.json", .{f});
            u.downloads = try gpa.dupe(u8, f);
        };
        return u;
    }

    /// Frees it, unless its thread is still at work (the app is ending).
    pub fn destroy(u: *Updater) void {
        if (u.busy.load(.acquire)) return;
        if (u.notice_arena) |*a| a.deinit();
        u.gpa.free(u.managed);
        u.gpa.free(u.search);
        if (u.latest.ptr != latest_url.ptr) u.gpa.free(u.latest);
        if (u.downloads.ptr != downloads.ptr) u.gpa.free(u.downloads);
        u.gpa.destroy(u);
    }

    /// Checks 30 s from now, then hourly. Call on the main thread.
    pub fn start(u: *Updater) void {
        nanoui.App.after(first_ms, u, tick);
    }

    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const u: *Updater = @ptrCast(@alignCast(ctx));
        u.checkNow();
        nanoui.App.after(every_ms, u, tick);
    }

    /// A graff session is starting: check, unless a check began in the
    /// last ten minutes. The session runs the graff it already found.
    pub fn checkSoon(u: *Updater) void {
        if (@import("blocks.zig").now() - u.last_check < debounce_s) return;
        u.checkNow();
    }

    /// Checks on a thread of its own, unless one is checking.
    pub fn checkNow(u: *Updater) void {
        u.last_check = @import("blocks.zig").now();
        if (u.busy.swap(true, .acq_rel)) return;
        const t = std.Thread.spawn(.{}, work, .{u}) catch {
            u.busy.store(false, .release);
            return;
        };
        t.detach();
    }

    fn work(u: *Updater) void {
        var arena: std.heap.ArenaAllocator = .init(u.gpa);
        const got = u.update(arena.allocator()) catch |e| blk: {
            std.log.info("nanoterm: graff not updated: {t}", .{e});
            break :blk null;
        };
        if (got == null) {
            arena.deinit();
            u.busy.store(false, .release);
            return;
        }
        const d = u.gpa.create(Delivery) catch {
            arena.deinit();
            u.busy.store(false, .release);
            return;
        };
        d.* = .{ .u = u, .arena = arena, .notice = got.? };
        nanoui.App.after(0, d, Delivery.run);
    }

    const Delivery = struct {
        u: *Updater,
        arena: std.heap.ArenaAllocator,
        notice: Notice,
        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const d: *Delivery = @ptrCast(@alignCast(ctx));
            defer d.u.gpa.destroy(d);
            d.u.publish(d.arena, d.notice);
            d.u.busy.store(false, .release);
        }
    };

    /// On the main thread: the notice an update made, in `arena` (now the
    /// updater's).
    pub fn publish(u: *Updater, arena: std.heap.ArenaAllocator, notice: Notice) void {
        if (u.notice_arena) |*a| a.deinit();
        u.notice_arena = arena;
        u.notice = notice;
        if (u.changed) |c| c.func(c.ctx);
    }

    /// "Got it": the card goes.
    pub fn dismiss(u: *Updater) void {
        u.notice = null;
    }

    /// Finds the latest stable release and, if it's newer than every graff
    /// there is, puts it in nanoterm's copy: the notice, or null when
    /// there was nothing to do. Blocks: for the thread, and tests.
    pub fn update(u: *Updater, a: std.mem.Allocator) !?Notice {
        const asset = assetName() orelse return error.NoBuildForThisPlatform;
        const release = try run(a, u.io, &.{ "/usr/bin/curl", "-fsSL", "--max-time", "30", "-H", "Accept: application/vnd.github+json", u.latest });
        const parsed = try std.json.parseFromSliceLeaky(struct { tag_name: []const u8 }, a, release, .{ .ignore_unknown_fields = true });
        const tag = parsed.tag_name;
        if (tag.len < 2 or tag[0] != 'v' or !nanoui.update.validVersion(tag[1..])) return error.BadTag;
        const latest = tag[1..];
        const was = resolve(a, u.io, u.search, u.managed);
        const current: ?[]const u8 = if (was) |p| versionOf(a, u.io, p) else null;
        if (current) |c| if (!newer(latest, c)) return null;

        const sums = try run(a, u.io, &.{ "/usr/bin/curl", "-fsSL", "--max-time", "30", try std.fmt.allocPrint(a, "{s}/{s}/SHA256SUMS", .{ u.downloads, tag }) });
        const expected = expectedSha(sums, asset) orelse return error.NotInSums;
        const dir = std.fs.path.dirname(u.managed).?;
        try std.Io.Dir.cwd().createDirPath(u.io, dir);
        const work_dir = try std.fmt.allocPrint(a, "{s}/.graff-update-{d}", .{ dir, std.Thread.getCurrentId() });
        std.Io.Dir.cwd().deleteTree(u.io, work_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(u.io, work_dir);
        defer std.Io.Dir.cwd().deleteTree(u.io, work_dir) catch {};
        const archive = try std.fs.path.join(a, &.{ work_dir, asset });
        _ = try run(a, u.io, &.{ "/usr/bin/curl", "-fsSL", "--max-time", "900", "-o", archive, try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ u.downloads, tag, asset }) });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(u.io, archive, a, .limited(max_archive));
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        if (!std.ascii.eqlIgnoreCase(&std.fmt.bytesToHex(digest, .lower), expected)) return error.ChecksumMismatch;
        _ = try run(a, u.io, &.{ "/usr/bin/tar", "-xzf", archive, "-C", work_dir });
        // Release archives nest `graff-<target>/graff`; repacked ones put it at the top.
        const nested = try std.fs.path.join(a, &.{ work_dir, asset[0 .. asset.len - ".tar.gz".len], "graff" });
        const binary = if (std.Io.Dir.cwd().access(u.io, nested, .{})) |_| nested else |_| try std.fs.path.join(a, &.{ work_dir, "graff" });
        const fetched = versionOf(a, u.io, binary) orelse return error.DownloadDoesNotRun;
        // Checked again: a graff installed meanwhile may be newer still.
        if (resolve(a, u.io, u.search, u.managed)) |p| if (versionOf(a, u.io, p)) |now| if (!newer(fetched, now)) return null;
        const staged = try std.fmt.allocPrint(a, "{s}/.graff.{d}.tmp", .{ dir, std.Thread.getCurrentId() });
        const exe = try std.Io.Dir.cwd().readFileAlloc(u.io, binary, a, .limited(max_archive));
        try std.Io.Dir.cwd().writeFile(u.io, .{ .sub_path = staged, .data = exe, .flags = .{ .permissions = exe_perms } });
        std.Io.Dir.renameAbsolute(staged, u.managed, u.io) catch |e| {
            std.Io.Dir.cwd().deleteFile(u.io, staged) catch {};
            return e;
        };
        const said = run(a, u.io, &.{ u.managed, "--version" }) catch "";
        return .{ .from = current orelse "", .to = fetched, .lines = try whatsNew(a, said, current, fetched) };
    }
};

const exe_perms: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o755);

fn off(v: []const u8) bool {
    const t = std.mem.trim(u8, v, " ");
    for ([_][]const u8{ "0", "false", "no", "off" }) |w| if (std.ascii.eqlIgnoreCase(t, w)) return true;
    return false;
}

/// nanoterm's own graff.
pub fn managedPath(gpa: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(gpa, &.{ home, "Library", "Application Support", "nanoterm", "bin", "graff" });
}

/// codegraff's release archive for this machine (`graff-aarch64-macos.tar.gz`).
pub fn assetName() ?[]const u8 {
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => return null,
    };
    const os = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => return null,
    };
    return "graff-" ++ arch ++ "-" ++ os ++ ".tar.gz";
}

/// The graff sessions run, as Harness picks it: `GRAFF_EXECUTABLE` if set
/// (resolved by the caller), else the newest of every graff on `search`
/// and nanoterm's copy. If the first found doesn't answer `--version`, it
/// is kept: a slow first run isn't a broken graff.
pub fn resolve(a: std.mem.Allocator, io: std.Io, search: []const u8, managed: []const u8) ?[]const u8 {
    var found: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, search, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const p = std.fs.path.join(a, &.{ dir, "graff" }) catch continue;
        add(a, io, &found, p);
    }
    add(a, io, &found, managed);
    if (found.items.len == 0) return null;
    var best = found.items[0];
    var best_v = versionOf(a, io, best) orelse return best;
    for (found.items[1..]) |p| {
        const v = versionOf(a, io, p) orelse continue;
        if (newer(v, best_v)) {
            best = p;
            best_v = v;
        }
    }
    return best;
}

fn add(a: std.mem.Allocator, io: std.Io, found: *std.ArrayList([]const u8), p: []const u8) void {
    std.Io.Dir.cwd().access(io, p, .{ .execute = true }) catch return;
    for (found.items) |q| if (std.mem.eql(u8, p, q)) return;
    found.append(a, p) catch {};
}

/// `graff --version`'s dotted version (`graff 0.302.46` → "0.302.46").
pub fn versionOf(a: std.mem.Allocator, io: std.Io, path: []const u8) ?[]const u8 {
    return dotted(run(a, io, &.{ path, "--version" }) catch return null);
}

/// The first word of `text` that is a dotted version (a `v` and a `-…`
/// suffix dropped), with at least three parts.
pub fn dotted(text: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (words.next()) |w| {
        const t = std.mem.trimStart(u8, w, "v");
        const v = t[0 .. std.mem.indexOfScalar(u8, t, '-') orelse t.len];
        if (nanoui.update.validVersion(v) and std.mem.count(u8, v, ".") >= 2) return v;
    }
    return null;
}

/// The sha256 SHA256SUMS gives `asset`.
pub fn expectedSha(sums: []const u8, asset: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeAny(u8, line, " \t\r*");
        const sha = parts.next() orelse continue;
        const name = parts.next() orelse continue;
        if (sha.len == 64 and std.mem.eql(u8, name, asset)) return sha;
    }
    return null;
}

/// The "What's new" lines `graff --version` lists for releases after
/// `from`, up to `to`, newest first; with no `from`, only `to`'s. Release
/// headers are bare versions; their lines start with `•`.
pub fn whatsNew(a: std.mem.Allocator, said: []const u8, from: ?[]const u8, to: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var in_range = false;
    var lines = std.mem.splitScalar(u8, said, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, "•")) {
            const item = std.mem.trim(u8, t["•".len..], " ");
            if (in_range and item.len > 0) try out.append(a, try a.dupe(u8, item));
        } else if (line.len > 0 and line[0] != ' ' and line[0] != '\t' and std.mem.indexOfAny(u8, t, " \t") == null) {
            const v = dotted(t) orelse continue;
            const upto = !newer(v, to);
            in_range = upto and if (from) |f| newer(v, f) else !newer(to, v);
        }
    }
    return out.items;
}

fn run(a: std.mem.Allocator, io: std.Io, argv: []const []const u8) ![]const u8 {
    const r = try std.process.run(a, io, .{ .argv = argv, .stdout_limit = .limited(4 << 20), .stderr_limit = .limited(1 << 20) });
    if (!r.term.success()) return error.CommandFailed;
    return r.stdout;
}

test "graff's versions, sums and release lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("0.302.46", dotted("graff 0.302.46\n\nWhat's new").?);
    try std.testing.expectEqualStrings("0.302.48", dotted("graff v0.302.48-beta.1").?);
    try std.testing.expect(dotted("graff 1.2") == null);
    try std.testing.expect(off("OFF") and off(" 0 ") and !off("1"));
    const sums = "1e8f  short\n332c8fe0f5674274062e6d5a700e4045bb960f8c1bd1168d137af8ab2c68c527  graff-aarch64-macos.tar.gz\n";
    try std.testing.expectEqualStrings("332c8fe0f5674274062e6d5a700e4045bb960f8c1bd1168d137af8ab2c68c527", expectedSha(sums, "graff-aarch64-macos.tar.gz").?);
    try std.testing.expect(expectedSha(sums, "graff-x86_64-linux.tar.gz") == null);
    const said =
        \\graff 0.302.47
        \\
        \\What's new
        \\──────────
        \\0.302.47
        \\  • images name their files
        \\
        \\0.302.46
        \\  • images over ACP reach hosted models
        \\  • a worker keeps its report
        \\
        \\0.302.45
        \\  • older
    ;
    const two = try whatsNew(a, said, "0.302.45", "0.302.47");
    try std.testing.expectEqual(@as(usize, 3), two.len);
    try std.testing.expectEqualStrings("images name their files", two[0]);
    try std.testing.expectEqualStrings("a worker keeps its report", two[2]);
    const only = try whatsNew(a, said, null, "0.302.46");
    try std.testing.expectEqual(@as(usize, 2), only.len);
}
