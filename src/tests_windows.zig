//! nanoterm's tests on Windows: the parts that don't depend on the OS, then
//! processes on pipes and on a pseudo console (cmd.exe), and PowerShell cut
//! into blocks by the integration. Under Wine (no real PowerShell) the
//! shell's test is skipped; CI runs it on Windows.
const std = @import("std");
const nanoui = @import("nanoui");
const proc = @import("proc.zig");
const shell_mod = @import("shell.zig");
const blocks = @import("blocks.zig");

test {
    _ = @import("vt.zig");
    _ = @import("tests_vt.zig");
    _ = @import("screen.zig");
    _ = @import("screen_vt.zig");
    _ = @import("markdown.zig");
    _ = @import("classify.zig");
    _ = @import("graff_logins.zig");
    _ = @import("proc_windows.zig");
    _ = @import("blocks.zig");
}

extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: u32) callconv(.winapi) u32;

/// This process's variable `name` (any case), from Windows itself.
fn variable(a: std.mem.Allocator, name: []const u8) !?[]const u8 {
    const w = try std.unicode.utf8ToUtf16LeAllocZ(a, name);
    const n = GetEnvironmentVariableW(w, null, 0);
    if (n == 0) return null;
    const buf = try a.alloc(u16, n);
    const got = GetEnvironmentVariableW(w, buf.ptr, n);
    if (got == 0 or got >= n) return null;
    return try std.unicode.utf16LeToUtf8Alloc(a, buf[0..got]);
}

extern "kernel32" fn GetModuleHandleW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

fn underWine() bool {
    const ntdll = GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("ntdll.dll")) orelse return false;
    return GetProcAddress(ntdll, "wine_get_version") != null;
}

const Run = struct {
    out: std.ArrayList(u8) = .empty,
    code: ?i32 = null,
    fn output(ctx: *anyopaque, bytes: []const u8) void {
        const r: *Run = @ptrCast(@alignCast(ctx));
        r.out.appendSlice(std.testing.allocator, bytes) catch {};
    }
    fn exited(ctx: *anyopaque, code: i32) void {
        const r: *Run = @ptrCast(@alignCast(ctx));
        r.code = code;
    }
    fn sink(r: *Run) proc.Sink {
        return .{ .ctx = r, .output = output, .exited = exited };
    }
    fn wait(r: *Run) !void {
        var waited: usize = 0;
        while (r.code == null) : (waited += 1) {
            if (waited > 1000) return error.Timeout;
            nanoui.runFor(0.01);
        }
    }
};

fn env(arena: std.mem.Allocator) ![*:null]const ?[*:0]const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "SystemRoot", "PATH", "TEMP", "USERPROFILE", "COMPUTERNAME" }) |k| {
        const v = std.testing.environ.getAlloc(arena, k) catch continue;
        try items.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ k, v }));
    }
    return proc.cStrings(arena, items.items);
}

test "programs on pipes: their output, then their exit code; stderr to a tail" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Run = .{};
    defer r.out.deinit(std.testing.allocator);
    var p: proc.Process = undefined;
    try proc.spawnPipes(&p, try proc.cStrings(a, &.{ "cmd.exe", "/d", "/c", "echo hello from cmd& exit 3" }), try env(a), null, true, r.sink());
    defer p.close();
    try r.wait();
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "hello from cmd") != null);
    try std.testing.expectEqual(@as(?i32, 3), r.code);

    // Input to the end, read back (sort reads all of it first).
    var s: Run = .{};
    defer s.out.deinit(std.testing.allocator);
    var q: proc.Process = undefined;
    try proc.spawnPipes(&q, try proc.cStrings(a, &.{ "sort.exe" }), try env(a), null, true, s.sink());
    defer q.close();
    q.send("pear\r\napple\r\n");
    q.closeInput();
    try s.wait();
    try std.testing.expect(std.mem.indexOf(u8, s.out.items, "apple").? < std.mem.indexOf(u8, s.out.items, "pear").?);

    var tail: proc.Tail = .{ .gpa = std.testing.allocator };
    defer tail.deinit();
    try tail.open();
    var t: Run = .{};
    defer t.out.deinit(std.testing.allocator);
    var e: proc.Process = undefined;
    try proc.spawnPipesErr(&e, try proc.cStrings(a, &.{ "cmd.exe", "/d", "/c", "echo out& echo went wrong 1>&2" }), try env(a), null, false, tail.write_fd, t.sink());
    tail.closeWriteEnd();
    defer e.close();
    try t.wait();
    var waited: usize = 0;
    while (tail.lastLine().len == 0 and waited < 200) : (waited += 1) nanoui.runFor(0.01);
    try std.testing.expectEqualStrings("went wrong", tail.lastLine());
    try std.testing.expect(std.mem.indexOf(u8, t.out.items, "went wrong") == null);
}

test "a program on a pseudo console: what it draws, then its end" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Run = .{};
    defer r.out.deinit(std.testing.allocator);
    var p: proc.Process = undefined;
    const dir = try a.dupeSentinel(u8, std.testing.environ.getAlloc(a, "TEMP") catch "C:\\", 0);
    try proc.spawnPty(&p, try proc.cStrings(a, &.{ "cmd.exe", "/d", "/c", "echo on the console& ping -n 2 127.0.0.1 >nul& exit 4" }), try env(a), dir, .{ .rows = 24, .cols = 80 }, r.sink());
    defer p.close();
    p.resize(30, 100);
    try r.wait();
    errdefer std.debug.print("console output: {any} code {any}\n", .{ r.out.items, r.code });
    try std.testing.expect(std.mem.indexOf(u8, r.out.items, "on the console") != null);
    try std.testing.expectEqual(@as(?i32, 4), r.code);
}

const Seen = struct {
    changed: usize = 0,
    fn onChanged(ctx: *anyopaque) void {
        const s: *Seen = @ptrCast(@alignCast(ctx));
        s.changed += 1;
    }
    fn onExited(_: *anyopaque, _: i32) void {}
};

fn until(sh: *shell_mod.Shell, comptime done: fn (*shell_mod.Shell) bool) !void {
    var waited: usize = 0;
    while (!done(sh)) : (waited += 1) {
        if (waited > 3000) return error.Timeout;
        nanoui.runFor(0.01);
    }
}

test "PowerShell cut into blocks: output, exit codes, the folder it moves to" {
    if (underWine()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const temp = std.testing.environ.getAlloc(a, "TEMP") catch "C:\\";
    const dir = try std.fs.path.join(a, &.{ temp, "nanoterm-test-pwsh" });
    var map: std.process.Environ.Map = .init(a);
    for ([_][]const u8{ "SystemRoot", "PATH", "PATHEXT", "TEMP", "TMP", "USERPROFILE", "COMPUTERNAME", "PSModulePath", "windir", "ProgramFiles", "ProgramData", "APPDATA", "LOCALAPPDATA", "SystemDrive", "ComSpec" }) |k| {
        if (try variable(a, k)) |v| try map.put(k, v);
    }
    var seen: Seen = .{};
    var sh = shell_mod.Shell.init(gpa, .{ .ctx = &seen, .changed = Seen.onChanged, .exited = Seen.onExited });
    defer sh.deinit();
    try sh.start(a, io, dir, temp, &map, temp, .{ .rows = 30, .cols = 100 });
    try until(&sh, struct {
        fn ok(s: *shell_mod.Shell) bool {
            return s.phase == .ready;
        }
    }.ok);

    const b1 = try blocks.Block.create(gpa, 1, .shell, "Write-Output 'hello blocks'", temp, "");
    defer b1.destroy(gpa);
    sh.submit(b1);
    try until(&sh, struct {
        fn ok(s: *shell_mod.Shell) bool {
            return !s.busy();
        }
    }.ok);
    const out = try b1.output.plainText(gpa);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello blocks") != null);
    try std.testing.expectEqual(@as(i32, 0), b1.exit_code.?);

    const b2 = try blocks.Block.create(gpa, 2, .shell, "cmd /c exit 3", temp, "");
    defer b2.destroy(gpa);
    sh.submit(b2);
    try until(&sh, struct {
        fn ok(s: *shell_mod.Shell) bool {
            return !s.busy();
        }
    }.ok);
    // What PowerShell itself makes of it, shown if the code is wrong.
    const b2x = try blocks.Block.create(gpa, 4, .shell, "\"lec=$LASTEXITCODE tp=$env:TERM_PROGRAM path=$env:Path\"", temp, "");
    defer b2x.destroy(gpa);
    sh.submit(b2x);
    try until(&sh, struct {
        fn ok(s: *shell_mod.Shell) bool {
            return !s.busy();
        }
    }.ok);
    const after = try b2x.output.plainText(gpa);
    defer gpa.free(after);
    const b2_out = try b2.output.plainText(gpa);
    defer gpa.free(b2_out);
    errdefer std.debug.print("exit 3 block: code {any}, output {s}; then {s}\n", .{ b2.exit_code, b2_out, after });
    try std.testing.expectEqual(@as(i32, 3), b2.exit_code.?);

    const b3 = try blocks.Block.create(gpa, 3, .shell, "Set-Location C:\\Windows", temp, "");
    defer b3.destroy(gpa);
    sh.submit(b3);
    try until(&sh, struct {
        fn ok(s: *shell_mod.Shell) bool {
            return !s.busy();
        }
    }.ok);
    try std.testing.expect(std.ascii.eqlIgnoreCase("C:\\Windows", sh.cwd.items));
}

test "a PowerShell listing keeps its blank lines and header, as Windows draws them" {
    if (underWine()) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const temp = (try variable(a, "TEMP")) orelse "C:\\";
    const dir = try std.fs.path.join(a, &.{ temp, "nanoterm-test-pwsh-raw" });
    var map: std.process.Environ.Map = .init(a);
    for ([_][]const u8{ "SystemRoot", "PATH", "PATHEXT", "TEMP", "TMP", "USERPROFILE", "COMPUTERNAME", "PSModulePath", "windir", "ProgramFiles", "ProgramData", "APPDATA", "LOCALAPPDATA", "SystemDrive", "ComSpec" }) |k| {
        if (try variable(a, k)) |v| try map.put(k, v);
    }
    var seen: Seen = .{};
    var sh = shell_mod.Shell.init(gpa, .{ .ctx = &seen, .changed = Seen.onChanged, .exited = Seen.onExited });
    defer sh.deinit();
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    sh.raw = &raw;
    try sh.start(a, io, dir, temp, &map, temp, .{ .rows = 30, .cols = 100 });
    try until(&sh, struct {
        fn ok(s: *shell_mod.Shell) bool {
            return s.phase == .ready;
        }
    }.ok);
    for ([_][]const u8{ "echo hello from Windows", "ls C:\\Windows\\Web" }, 0..) |cmd, i| {
        const b = try blocks.Block.create(gpa, 10 + i, .shell, cmd, temp, "");
        defer b.destroy(gpa);
        sh.submit(b);
        try until(&sh, struct {
            fn ok(s: *shell_mod.Shell) bool {
                return !s.busy();
            }
        }.ok);
        const out = try b.output.plainText(gpa);
        defer gpa.free(out);
        errdefer std.debug.print("block {f}\nsession {f}\n", .{ std.zig.fmtString(out), std.zig.fmtString(raw.items) });
        if (i == 0) try std.testing.expectEqualStrings("hello\nfrom\nWindows", out);
        if (i == 1) try std.testing.expect(std.mem.indexOf(u8, out, "Directory: C:\\Windows\\Web\n\nMode ") != null);
    }
}
