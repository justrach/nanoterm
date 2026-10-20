//! Child processes: a shell on a pseudo-terminal, and programs on pipes
//! (ACP agents, the commands agents run), their output handed to a Sink on
//! the main thread. proc_posix.zig (forkpty, posix_spawn) on macOS and
//! Linux; proc_windows.zig (ConPTY, CreateProcessW) on Windows.
const std = @import("std");
const builtin = @import("builtin");

pub const windows = builtin.os.tag == .windows;
const impl = if (windows) @import("proc_windows.zig") else @import("proc_posix.zig");

pub const Process = impl.Process;
pub const Tail = impl.Tail;
/// A pipe's end: a file descriptor, or a Windows handle.
pub const Fd = impl.Fd;
pub const spawnPty = impl.spawnPty;
pub const spawnPipes = impl.spawnPipes;
pub const spawnPipesErr = impl.spawnPipesErr;

pub const Winsize = extern struct { rows: u16, cols: u16, xpixel: u16 = 0, ypixel: u16 = 0 };

pub const SIGINT = 2;
pub const SIGTERM = 15;

/// `sh -c LINE`, or on Windows `cmd /c LINE`: a command line to run.
pub fn shellLine(line: []const u8) [if (windows) 5 else 3][]const u8 {
    return if (windows) .{ "cmd.exe", "/d", "/s", "/c", line } else .{ "/bin/sh", "-c", line };
}

/// curl (Windows ships it too) and the little environment it needs.
pub const curl = if (windows) "C:\\Windows\\System32\\curl.exe" else "/usr/bin/curl";
pub const curl_env: []const []const u8 = if (windows) &.{"SystemRoot=C:\\Windows"} else &.{"PATH=/usr/bin:/bin"};

/// What a process does with its output and its end, on the main thread.
pub const Sink = struct {
    ctx: *anyopaque,
    output: *const fn (ctx: *anyopaque, bytes: []const u8) void,
    exited: *const fn (ctx: *anyopaque, code: i32) void,
};

/// Null-terminated argv/envp for exec, in `arena`.
pub fn cStrings(arena: std.mem.Allocator, items: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const out = try arena.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, 0..) |s, i| out[i] = try arena.dupeSentinel(u8, s, 0);
    return out;
}

/// The full path of `name` on `path_env` (the OS's list of folders), if
/// any. On Windows a name without an extension is tried with PATHEXT's
/// usual ones too (graff.exe, npx.cmd).
pub fn which(arena: std.mem.Allocator, io: std.Io, path_env: []const u8, name: []const u8) ?[]const u8 {
    const exts: []const []const u8 = if (windows and std.fs.path.extension(name).len == 0) &.{ ".exe", ".cmd", ".bat", "" } else &.{""};
    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        for (exts) |ext| {
            const full = std.fmt.allocPrint(arena, "{s}{c}{s}{s}", .{ dir, std.fs.path.sep, name, ext }) catch continue;
            std.Io.Dir.cwd().access(io, full, .{ .execute = !windows }) catch continue;
            return full;
        }
    }
    return null;
}
