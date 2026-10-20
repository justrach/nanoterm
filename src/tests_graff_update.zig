//! graff kept current: a release in a folder (`NANOTERM_GRAFF_FEED`, curl
//! reads file:// as it reads https://) with fake graffs that only print
//! their versions. Nothing reaches GitHub or the user's graff; HOME is a
//! temporary folder. And the card that announces an update.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const gu = @import("graff_update.zig");
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");

const root = "/tmp/nanoterm-test-graff-update";

/// A graff that prints its version and, like graff, what's new.
fn fakeGraff(a: std.mem.Allocator, io: std.Io, path: []const u8, version: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    const script = try std.fmt.allocPrint(a, "#!/bin/sh\nprintf 'graff {s}\\n\\nWhat'\\''s new\\n──────────\\n{s}\\n  • the newest thing\\n  • a second thing\\n\\n0.1.0\\n  • an old thing\\n'\n", .{ version, version });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = script, .flags = .{ .permissions = .fromMode(0o755) } });
}

/// A release `tag` in the feed: its archive and SHA256SUMS (`bad`: a wrong sum).
fn release(a: std.mem.Allocator, io: std.Io, tag: []const u8, bad: bool) !void {
    const asset = gu.assetName().?;
    const stem = asset[0 .. asset.len - ".tar.gz".len];
    const dir = try std.fmt.allocPrint(a, root ++ "/feed/{s}", .{tag});
    const pack = try std.fmt.allocPrint(a, root ++ "/pack-{s}", .{tag});
    try fakeGraff(a, io, try std.fmt.allocPrint(a, "{s}/{s}/graff", .{ pack, stem }), tag[1..]);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const archive = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, asset });
    const r = try std.process.run(a, io, .{ .argv = &.{ "/usr/bin/tar", "-czf", archive, "-C", pack, stem } });
    try std.testing.expect(r.term.success());
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, archive, a, .limited(1 << 20));
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (bad) digest[0] +%= 1;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/SHA256SUMS", .{dir}), .data = try std.fmt.allocPrint(a, "{s}  {s}\n", .{ std.fmt.bytesToHex(digest, .lower), asset }) });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = root ++ "/feed/latest.json", .data = try std.fmt.allocPrint(a, "{{\"tag_name\":\"{s}\",\"name\":\"graff\"}}", .{tag}) });
}

test "graff is updated from the latest release, verified, and run newest" {
    if (gu.assetName() == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try fakeGraff(a, io, root ++ "/old/graff", "0.1.0");
    try release(a, io, "v9.9.9", false);

    var env: std.process.Environ.Map = .init(a);
    try env.put("HOME", root ++ "/home");
    try env.put("NANOTERM_GRAFF_FEED", "file://" ++ root ++ "/feed");
    // A graff of the user's own, or updates turned off: none is made.
    try env.put("GRAFF_EXECUTABLE", "/opt/mine/graff");
    try std.testing.expect(try gu.Updater.create(gpa, io, &env, root ++ "/old") == null);
    _ = env.swapRemove("GRAFF_EXECUTABLE");
    try env.put("NANOTERM_GRAFF_AUTO_UPDATE", "off");
    try std.testing.expect(try gu.Updater.create(gpa, io, &env, root ++ "/old") == null);
    _ = env.swapRemove("NANOTERM_GRAFF_AUTO_UPDATE");

    const u = (try gu.Updater.create(gpa, io, &env, root ++ "/old")).?;
    defer u.destroy();
    try std.testing.expectEqualStrings(root ++ "/old/graff", gu.resolve(a, io, u.search, u.managed).?);
    // Older than the release: it's fetched, checked and put in nanoterm's copy.
    const n = (try u.update(a)).?;
    try std.testing.expectEqualStrings("0.1.0", n.from);
    try std.testing.expectEqualStrings("9.9.9", n.to);
    try std.testing.expectEqual(@as(usize, 2), n.lines.len);
    try std.testing.expectEqualStrings("the newest thing", n.lines[0]);
    try std.testing.expectEqualStrings("9.9.9", gu.versionOf(a, io, u.managed).?);
    // Sessions run it now; nothing is left beside it.
    try std.testing.expectEqualStrings(u.managed, gu.resolve(a, io, u.search, u.managed).?);
    var dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(u.managed).?, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var files: usize = 0;
    while (try it.next(io)) |_| files += 1;
    try std.testing.expectEqual(@as(usize, 1), files);
    // Current: nothing to do.
    try std.testing.expect(try u.update(a) == null);
    // A release whose archive doesn't match its sum is refused.
    try release(a, io, "v9.9.10", true);
    try std.testing.expectError(error.ChecksumMismatch, u.update(a));
    try std.testing.expectEqualStrings("9.9.9", gu.versionOf(a, io, u.managed).?);
    // A graff already newer than the release: nothing is downloaded.
    try fakeGraff(a, io, root ++ "/old/graff", "10.0.0");
    try std.testing.expect(try u.update(a) == null);
    try std.testing.expectEqualStrings(root ++ "/old/graff", gu.resolve(a, io, u.search, u.managed).?);
}

test "an updated graff is announced on a card until \"Got it\"" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = root ++ "-card";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    _ = try w.newTab(home);
    var u: gu.Updater = .{ .gpa = gpa, .io = io, .managed = "", .search = "" };
    gu.global = &u;
    defer {
        gu.global = null;
        if (u.notice_arena) |*na| na.deinit();
    }
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1000, .height = 640, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    try std.testing.expect(!t.hasText("Codegraff engine updated"));
    var na: std.heap.ArenaAllocator = .init(gpa);
    const lines = try na.allocator().dupe([]const u8, &.{ "images name their files", "a worker keeps its report", "the meter counts what was kept out", "sign-in across clients", "one more" });
    u.publish(na, .{ .from = "0.302.46", .to = "0.302.47", .lines = lines });
    t.settle(1);
    try std.testing.expect(t.hasText("Codegraff engine updated"));
    try std.testing.expect(t.hasText("v0.302.47"));
    try std.testing.expect(t.hasText("images name their files"));
    try std.testing.expect(t.hasText("+1 more in the release notes"));
    try std.testing.expect(!t.hasText("one more"));
    try t.screenshot("/tmp/nanoterm-graff-card.png");
    try t.clickText("Got it");
    t.settle(1);
    try std.testing.expect(!t.hasText("Codegraff engine updated"));
}
