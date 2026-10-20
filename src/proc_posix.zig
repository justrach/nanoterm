//! Child processes on macOS and Linux: a shell on a pseudo-terminal
//! (`forkpty`), and programs on pipes (`posix_spawn`). Their output is read
//! on the main thread when it arrives (`nanoui.fdwatch`). proc.zig picks it.
const std = @import("std");
const nanoui = @import("nanoui");
const fdwatch = nanoui.fdwatch;
const proc = @import("proc.zig");
const Winsize = proc.Winsize;
const Sink = proc.Sink;

/// What a pipe's end is.
pub const Fd = c_int;

extern "c" fn forkpty(master: *c_int, name: ?[*]u8, termp: ?*anyopaque, winp: ?*const Winsize) c_int;
extern "c" fn execve(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn ioctl(fd: c_int, req: c_ulong, ...) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn usleep(us: c_uint) c_int;
const WNOHANG = 1;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn posix_spawn(pid: *c_int, path: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, actions: ?*const anyopaque, attr: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn posix_spawn_file_actions_init(a: *FileActions) c_int;
extern "c" fn posix_spawn_file_actions_destroy(a: *FileActions) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(a: *FileActions, fd: c_int, newfd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addclose(a: *FileActions, fd: c_int) c_int;
extern "c" fn posix_spawn_file_actions_addchdir_np(a: *FileActions, path: [*:0]const u8) c_int;
extern "c" fn posix_spawnattr_init(a: *SpawnAttr) c_int;
extern "c" fn posix_spawnattr_setflags(a: *SpawnAttr, flags: c_short) c_int;
extern "c" fn posix_spawnattr_destroy(a: *SpawnAttr) c_int;

// What differs between macOS's libc and glibc.
const linux = @import("builtin").os.tag == .linux;
const FileActions = if (linux) extern struct { bytes: [80]u8 align(8) = @splat(0) } else extern struct { ptr: ?*anyopaque = null };
const SpawnAttr = if (linux) extern struct { bytes: [336]u8 align(8) = @splat(0) } else extern struct { ptr: ?*anyopaque = null };
const TIOCSWINSZ: c_ulong = if (linux) 0x5414 else 0x80087467;
const F_SETFL = 4;
const O_NONBLOCK = if (linux) 0o4000 else 0x4;
const POSIX_SPAWN_SETSID: c_short = if (linux) 0x80 else 0x0400;
const SIGKILL = 9;

/// A running child: its pid, the fd it reads, the fd its output comes on.
pub const Process = struct {
    pid: c_int,
    input: c_int,
    output: c_int,
    sink: Sink,
    read_watch: ?fdwatch.Watch = null,
    exit_watch: ?fdwatch.Watch = null,
    exit_code: ?i32 = null,
    closed: bool = false,

    fn watch(p: *Process) !void {
        _ = fcntl(p.output, F_SETFL, @as(c_int, O_NONBLOCK));
        p.read_watch = try fdwatch.readable(p.output, p, onReadable);
        p.exit_watch = try fdwatch.exited(p.pid, p, onExit);
    }

    fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Process = @ptrCast(@alignCast(ctx));
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = read(p.output, &buf, buf.len);
            if (n > 0) {
                p.sink.output(p.sink.ctx, buf[0..@intCast(n)]);
                if (n < buf.len) return;
                continue;
            }
            // End of file (n == 0), or nothing more now (EAGAIN).
            if (n == 0) p.stopReading();
            return;
        }
    }

    fn stopReading(p: *Process) void {
        if (p.read_watch) |w| w.cancel();
        p.read_watch = null;
    }

    fn onExit(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Process = @ptrCast(@alignCast(ctx));
        // What is left in the pipe comes before the end.
        onReadable(p);
        var status: c_int = 0;
        _ = waitpid(p.pid, &status, 0);
        const code: i32 = if (status & 0x7f == 0) (status >> 8) & 0xff else 128 + (status & 0x7f);
        p.exit_code = code;
        if (p.exit_watch) |w| w.cancel();
        p.exit_watch = null;
        p.sink.exited(p.sink.ctx, code);
    }

    /// Writes all of `bytes` to the process.
    pub fn send(p: *Process, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0) {
            const n = write(p.input, rest.ptr, rest.len);
            if (n <= 0) return;
            rest = rest[@intCast(n)..];
        }
    }

    /// Closes its input: the process reads to the end of what was sent.
    pub fn closeInput(p: *Process) void {
        if (p.input < 0 or p.input == p.output) return;
        _ = close_(p.input);
        p.input = -1;
    }

    pub fn signal(p: *Process, sig: c_int) void {
        if (p.exit_code == null) _ = kill(p.pid, sig);
    }

    pub fn resize(p: *Process, rows: u16, cols: u16) void {
        const ws: Winsize = .{ .rows = rows, .cols = cols };
        _ = ioctl(p.output, TIOCSWINSZ, &ws);
    }

    /// Stops watching, closes the fds, and kills the process if it runs.
    /// The fds close first: a process exiting while its terminal has
    /// output nobody reads would wait for it forever (a hang-up frees it).
    pub fn close(p: *Process) void {
        if (p.closed) return;
        p.closed = true;
        p.stopReading();
        if (p.exit_watch) |w| w.cancel();
        p.exit_watch = null;
        if (p.input >= 0) _ = close_(p.input);
        if (p.output != p.input) _ = close_(p.output);
        if (p.exit_code == null) {
            _ = kill(p.pid, SIGKILL);
            // Reap it if it is gone already; never block on it.
            var status: c_int = 0;
            var tries: usize = 0;
            while (tries < 50) : (tries += 1) {
                if (waitpid(p.pid, &status, WNOHANG) != 0) break;
                _ = usleep(1000);
            }
        }
    }
};

fn close_(fd: c_int) c_int {
    return close(fd);
}

/// Starts `argv` on a new pseudo-terminal, as a terminal starts a shell.
pub fn spawnPty(p: *Process, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: [*:0]const u8, size: Winsize, sink: Sink) !void {
    var master: c_int = -1;
    const pid = forkpty(&master, null, null, &size);
    if (pid < 0) return error.ForkPty;
    if (pid == 0) {
        // The child: only async-signal-safe calls from here to exec.
        _ = chdir(cwd);
        _ = execve(argv[0].?, argv, envp);
        _exit(127);
    }
    p.* = .{ .pid = pid, .input = master, .output = master, .sink = sink };
    try p.watch();
}

/// Starts `argv` with pipes for its input and its output (stderr merged
/// into stdout when `merge_stderr`, else into `stderr_fd` if given), in `cwd`.
pub fn spawnPipes(p: *Process, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: ?[*:0]const u8, merge_stderr: bool, sink: Sink) !void {
    return spawnPipesErr(p, argv, envp, cwd, merge_stderr, null, sink);
}

pub fn spawnPipesErr(p: *Process, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: ?[*:0]const u8, merge_stderr: bool, stderr_fd: ?c_int, sink: Sink) !void {
    var in_fds: [2]c_int = undefined;
    var out_fds: [2]c_int = undefined;
    if (pipe(&in_fds) != 0) return error.Pipe;
    if (pipe(&out_fds) != 0) return error.Pipe;
    var fa: FileActions = .{};
    _ = posix_spawn_file_actions_init(&fa);
    defer _ = posix_spawn_file_actions_destroy(&fa);
    _ = posix_spawn_file_actions_adddup2(&fa, in_fds[0], 0);
    _ = posix_spawn_file_actions_adddup2(&fa, out_fds[1], 1);
    if (merge_stderr) _ = posix_spawn_file_actions_adddup2(&fa, out_fds[1], 2) else if (stderr_fd) |fd| _ = posix_spawn_file_actions_adddup2(&fa, fd, 2);
    for ([_]c_int{ in_fds[0], in_fds[1], out_fds[0], out_fds[1] }) |fd| _ = posix_spawn_file_actions_addclose(&fa, fd);
    if (cwd) |dir| _ = posix_spawn_file_actions_addchdir_np(&fa, dir);
    var attr: SpawnAttr = .{};
    _ = posix_spawnattr_init(&attr);
    defer _ = posix_spawnattr_destroy(&attr);
    // Its own session: signals for the terminal never reach it.
    _ = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);
    var pid: c_int = 0;
    const rc = posix_spawnp(&pid, argv[0].?, &fa, &attr, argv, envp);
    _ = close(in_fds[0]);
    _ = close(out_fds[1]);
    if (rc != 0) {
        _ = close(in_fds[1]);
        _ = close(out_fds[0]);
        return error.Spawn;
    }
    p.* = .{ .pid = pid, .input = in_fds[1], .output = out_fds[0], .sink = sink };
    try p.watch();
}

/// A pipe whose read end is watched: what a process writes to the write
/// end (its stderr) is kept, the last `cap` bytes.
pub const Tail = struct {
    gpa: std.mem.Allocator,
    read_fd: c_int = -1,
    write_fd: c_int = -1,
    bytes: std.ArrayList(u8) = .empty,
    watch_: ?fdwatch.Watch = null,
    const cap = 4096;

    pub fn open(t: *Tail) !void {
        var fds: [2]c_int = undefined;
        if (pipe(&fds) != 0) return error.Pipe;
        t.read_fd = fds[0];
        t.write_fd = fds[1];
        _ = fcntl(t.read_fd, F_SETFL, @as(c_int, O_NONBLOCK));
        t.watch_ = try fdwatch.readable(t.read_fd, t, onReadable);
    }

    /// After the child started: only the child keeps the write end.
    pub fn closeWriteEnd(t: *Tail) void {
        if (t.write_fd >= 0) _ = close(t.write_fd);
        t.write_fd = -1;
    }

    fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
        const t: *Tail = @ptrCast(@alignCast(ctx));
        var buf: [4096]u8 = undefined;
        const n = read(t.read_fd, &buf, buf.len);
        if (n <= 0) {
            if (n == 0) if (t.watch_) |w| {
                w.cancel();
                t.watch_ = null;
            };
            return;
        }
        t.bytes.appendSlice(t.gpa, buf[0..@intCast(n)]) catch return;
        if (t.bytes.items.len > cap) {
            const drop = t.bytes.items.len - cap;
            std.mem.copyForwards(u8, t.bytes.items[0..cap], t.bytes.items[drop..]);
            t.bytes.items.len = cap;
        }
    }

    /// The last non-empty line written, if any.
    pub fn lastLine(t: *const Tail) []const u8 {
        var it = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, t.bytes.items, " \n\r"), '\n');
        while (it.next()) |l| if (std.mem.trim(u8, l, " \r").len > 0) return std.mem.trim(u8, l, " \r");
        return "";
    }

    pub fn deinit(t: *Tail) void {
        if (t.watch_) |w| w.cancel();
        if (t.read_fd >= 0) _ = close(t.read_fd);
        t.closeWriteEnd();
        t.bytes.deinit(t.gpa);
    }
};
