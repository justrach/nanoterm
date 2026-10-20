//! Child processes on Windows: the shell on a pseudo console (ConPTY), and
//! programs on pipes (CreateProcessW), read on threads of nanoui's fdwatch
//! that hand the bytes to the main thread. A child inherits exactly its own
//! pipe ends (PROC_THREAD_ATTRIBUTE_HANDLE_LIST), never another child's, so
//! each pipe ends when its child does. A process is reported exited once its
//! output has ended too: nothing it wrote comes after.
const std = @import("std");
const nanoui = @import("nanoui");
const fdwatch = nanoui.fdwatch;
const proc = @import("proc.zig");
const Winsize = proc.Winsize;
const Sink = proc.Sink;

pub const HANDLE = *anyopaque;
pub const Fd = HANDLE;
const BOOL = i32;
const HPCON = *anyopaque;

const Coord = extern struct { x: i16, y: i16 };
const SecurityAttributes = extern struct { len: u32 = @sizeOf(SecurityAttributes), descriptor: ?*anyopaque = null, inherit: BOOL = 0 };
const StartupInfoW = extern struct {
    cb: u32,
    reserved: ?[*:0]u16 = null,
    desktop: ?[*:0]u16 = null,
    title: ?[*:0]u16 = null,
    x: u32 = 0,
    y: u32 = 0,
    x_size: u32 = 0,
    y_size: u32 = 0,
    x_chars: u32 = 0,
    y_chars: u32 = 0,
    fill: u32 = 0,
    flags: u32 = 0,
    show: u16 = 0,
    reserved2_len: u16 = 0,
    reserved2: ?*u8 = null,
    stdin: ?HANDLE = null,
    stdout: ?HANDLE = null,
    stderr: ?HANDLE = null,
};
const StartupInfoExW = extern struct { info: StartupInfoW, attrs: ?*anyopaque };
const ProcessInformation = extern struct { process: HANDLE, thread: HANDLE, pid: u32, tid: u32 };

extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, attrs: ?*const SecurityAttributes, size: u32) callconv(.winapi) BOOL;
extern "kernel32" fn SetHandleInformation(h: HANDLE, mask: u32, flags: u32) callconv(.winapi) BOOL;
extern "kernel32" fn CreatePseudoConsole(size: Coord, input: HANDLE, output: HANDLE, flags: u32, pc: *HPCON) callconv(.winapi) i32;
extern "kernel32" fn ResizePseudoConsole(pc: HPCON, size: Coord) callconv(.winapi) i32;
extern "kernel32" fn ClosePseudoConsole(pc: HPCON) callconv(.winapi) void;
extern "kernel32" fn InitializeProcThreadAttributeList(list: ?*anyopaque, count: u32, flags: u32, size: *usize) callconv(.winapi) BOOL;
extern "kernel32" fn UpdateProcThreadAttribute(list: *anyopaque, flags: u32, attr: usize, value: ?*const anyopaque, size: usize, prev: ?*anyopaque, ret: ?*usize) callconv(.winapi) BOOL;
extern "kernel32" fn DeleteProcThreadAttributeList(list: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: [*:0]u16, pattrs: ?*anyopaque, tattrs: ?*anyopaque, inherit: BOOL, flags: u32, env: ?*const anyopaque, cwd: ?[*:0]const u16, si: *const StartupInfoW, pi: *ProcessInformation) callconv(.winapi) BOOL;
extern "kernel32" fn GetExitCodeProcess(h: HANDLE, code: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(h: HANDLE, code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, n: u32, written: *u32, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;

const HANDLE_FLAG_INHERIT = 1;
const STARTF_USESTDHANDLES = 0x100;
const EXTENDED_STARTUPINFO_PRESENT = 0x80000;
const CREATE_UNICODE_ENVIRONMENT = 0x400;
const CREATE_NO_WINDOW = 0x08000000;
const ATTR_HANDLE_LIST: usize = 0x20002;
const ATTR_PSEUDOCONSOLE: usize = 0x20016;

/// A running child: its process, the pipe it reads, the one its output
/// comes on, and its pseudo console if it has one.
pub const Process = struct {
    process: HANDLE,
    input: ?HANDLE,
    output: ?HANDLE,
    console: ?HPCON = null,
    sink: Sink,
    read_watch: ?fdwatch.Watch = null,
    exit_watch: ?fdwatch.Watch = null,
    exit_code: ?i32 = null,
    /// Its output ended (a pipe's end, or the closed pseudo console's).
    ended: bool = false,
    reported: bool = false,
    closed: bool = false,

    fn watch(p: *Process) !void {
        p.read_watch = try fdwatch.reader(p.output.?, p, onBytes, onEnd);
        p.exit_watch = try fdwatch.exited(p.process, p, onExit);
    }

    fn onBytes(ctx: ?*anyopaque, bytes: []const u8) void {
        const p: *Process = @ptrCast(@alignCast(ctx));
        p.sink.output(p.sink.ctx, bytes);
    }

    fn onEnd(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Process = @ptrCast(@alignCast(ctx));
        p.ended = true;
        p.report();
    }

    fn onExit(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Process = @ptrCast(@alignCast(ctx));
        var code: u32 = 0;
        _ = GetExitCodeProcess(p.process, &code);
        p.exit_code = @bitCast(code);
        // The pseudo console outlives its process: closing it flushes what
        // is left and ends the output.
        if (p.console) |pc| {
            ClosePseudoConsole(pc);
            p.console = null;
        }
        p.report();
    }

    fn report(p: *Process) void {
        const code = p.exit_code orelse return;
        if (!p.ended or p.reported) return;
        p.reported = true;
        p.sink.exited(p.sink.ctx, code);
    }

    /// Writes all of `bytes` to the process.
    pub fn send(p: *Process, bytes: []const u8) void {
        const h = p.input orelse return;
        var rest = bytes;
        while (rest.len > 0) {
            var n: u32 = 0;
            if (WriteFile(h, rest.ptr, @intCast(@min(rest.len, 1 << 20)), &n, null) == 0 or n == 0) return;
            rest = rest[n..];
        }
    }

    /// Closes its input: the process reads to the end of what was sent.
    pub fn closeInput(p: *Process) void {
        if (p.console != null) return;
        if (p.input) |h| _ = CloseHandle(h);
        p.input = null;
    }

    /// ^C reaches a pseudo console's program as the character; the other
    /// signals, and any to a program on pipes, end it.
    pub fn signal(p: *Process, sig: c_int) void {
        if (p.exit_code != null) return;
        if (sig == proc.SIGINT and p.console != null) return p.send("\x03");
        _ = TerminateProcess(p.process, 1);
    }

    pub fn resize(p: *Process, rows: u16, cols: u16) void {
        if (p.console) |pc| _ = ResizePseudoConsole(pc, .{ .x = @intCast(@max(cols, 1)), .y = @intCast(@max(rows, 1)) });
    }

    /// Stops watching, closes the pipes and the console, and ends the
    /// process if it runs. The output pipe closes before the console: an
    /// older ConPTY waits for its output to be read before it closes.
    pub fn close(p: *Process) void {
        if (p.closed) return;
        p.closed = true;
        if (p.read_watch) |w| w.cancel();
        if (p.exit_watch) |w| w.cancel();
        p.read_watch = null;
        p.exit_watch = null;
        if (p.output) |h| _ = CloseHandle(h);
        if (p.input) |h| _ = CloseHandle(h);
        p.output = null;
        p.input = null;
        if (p.console) |pc| ClosePseudoConsole(pc);
        p.console = null;
        if (p.exit_code == null) _ = TerminateProcess(p.process, 1);
        _ = CloseHandle(p.process);
    }
};

/// Appends `arg` to a command line as CommandLineToArgvW reads it back.
fn quote(out: *std.ArrayList(u8), a: std.mem.Allocator, arg: []const u8) !void {
    if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n\x0b\"") == null) return out.appendSlice(a, arg);
    try out.append(a, '"');
    var slashes: usize = 0;
    for (arg) |ch| {
        if (ch == '\\') {
            slashes += 1;
            continue;
        }
        const n = if (ch == '"') slashes * 2 + 1 else slashes;
        try out.appendNTimes(a, '\\', n);
        try out.append(a, ch);
        slashes = 0;
    }
    try out.appendNTimes(a, '\\', slashes * 2);
    try out.append(a, '"');
}

/// The command line for `argv`; a batch file (npx.cmd) runs in cmd.exe.
pub fn commandLine(a: std.mem.Allocator, argv: [*:null]const ?[*:0]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (argv[i]) |arg| : (i += 1) {
        if (i > 0) try out.append(a, ' ');
        try quote(&out, a, std.mem.span(arg));
    }
    const first = std.mem.span(argv[0].?);
    const ext = std.fs.path.extension(first);
    if (std.ascii.eqlIgnoreCase(ext, ".cmd") or std.ascii.eqlIgnoreCase(ext, ".bat")) {
        return std.fmt.allocPrint(a, "cmd.exe /d /s /c \"{s}\"", .{out.items});
    }
    return out.items;
}

/// `KEY=value` strings as a sorted UTF-16 environment block.
fn envBlock(a: std.mem.Allocator, envp: [*:null]const ?[*:0]const u8) ![]u16 {
    var items: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (envp[i]) |e| : (i += 1) try items.append(a, std.mem.span(e));
    std.mem.sort([]const u8, items.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.ascii.lessThanIgnoreCase(x, y);
        }
    }.lt);
    var out: std.ArrayList(u16) = .empty;
    for (items.items) |e| {
        try out.appendSlice(a, try std.unicode.utf8ToUtf16LeAlloc(a, e));
        try out.append(a, 0);
    }
    if (items.items.len == 0) try out.append(a, 0);
    try out.append(a, 0);
    return out.items;
}

const Attr = struct { id: usize, value: *const anyopaque, size: usize };

/// CreateProcessW with `attrs` (the handles it inherits, its console).
fn create(argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: ?[*:0]const u8, attrs: []const Attr, stdio: ?[3]HANDLE) !HANDLE {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, @intCast(attrs.len), 0, &size);
    const list = try a.alignedAlloc(u8, .of(usize), size);
    if (InitializeProcThreadAttributeList(list.ptr, @intCast(attrs.len), 0, &size) == 0) return error.Spawn;
    defer DeleteProcThreadAttributeList(list.ptr);
    for (attrs) |at| if (UpdateProcThreadAttribute(list.ptr, 0, at.id, at.value, at.size, null, null) == 0) return error.Spawn;
    // Standard handles named, or none: never this process's own. A pseudo
    // console's program gets null ones, so it takes the console's; without
    // the flag it would take this process's when they are pipes (a test
    // runner's, CI's) and write past the console.
    var si: StartupInfoExW = .{ .info = .{ .cb = @sizeOf(StartupInfoExW), .flags = STARTF_USESTDHANDLES }, .attrs = list.ptr };
    if (stdio) |s| {
        si.info.stdin = s[0];
        si.info.stdout = s[1];
        si.info.stderr = s[2];
    }
    const cmd = try std.unicode.utf8ToUtf16LeAllocZ(a, try commandLine(a, argv));
    const env = try envBlock(a, envp);
    const dir = if (cwd) |d| try std.unicode.utf8ToUtf16LeAllocZ(a, std.mem.span(d)) else null;
    var pi: ProcessInformation = undefined;
    // On pipes, a console program shows no console window; on a pseudo
    // console it has that one (CREATE_NO_WINDOW would take it away).
    const flags: u32 = EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT | @as(u32, if (stdio != null) CREATE_NO_WINDOW else 0);
    if (CreateProcessW(null, cmd, null, null, @intFromBool(stdio != null), flags, env.ptr, if (dir) |d| d.ptr else null, &si.info, &pi) == 0) return error.Spawn;
    _ = CloseHandle(pi.thread);
    return pi.process;
}

fn pipe(inherit_read: bool) ![2]HANDLE {
    var r: HANDLE = undefined;
    var w: HANDLE = undefined;
    const sa: SecurityAttributes = .{};
    if (CreatePipe(&r, &w, &sa, 0) == 0) return error.Pipe;
    // Only the child's end is inheritable, and only by the child it is
    // listed for.
    _ = SetHandleInformation(if (inherit_read) r else w, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT);
    return .{ r, w };
}

/// Starts `argv` on a new pseudo console, as a terminal starts a shell.
pub fn spawnPty(p: *Process, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: [*:0]const u8, size: Winsize, sink: Sink) !void {
    var in_r: HANDLE = undefined;
    var in_w: HANDLE = undefined;
    var out_r: HANDLE = undefined;
    var out_w: HANDLE = undefined;
    if (CreatePipe(&in_r, &in_w, null, 0) == 0) return error.Pipe;
    if (CreatePipe(&out_r, &out_w, null, 0) == 0) return error.Pipe;
    var pc: HPCON = undefined;
    const hr = CreatePseudoConsole(.{ .x = @intCast(@max(size.cols, 1)), .y = @intCast(@max(size.rows, 1)) }, in_r, out_w, 0, &pc);
    // The console has its own copies now.
    _ = CloseHandle(in_r);
    _ = CloseHandle(out_w);
    if (hr < 0) {
        _ = CloseHandle(in_w);
        _ = CloseHandle(out_r);
        return error.PseudoConsole;
    }
    const process = create(argv, envp, cwd, &.{.{ .id = ATTR_PSEUDOCONSOLE, .value = pc, .size = @sizeOf(HPCON) }}, null) catch |e| {
        ClosePseudoConsole(pc);
        _ = CloseHandle(in_w);
        _ = CloseHandle(out_r);
        return e;
    };
    p.* = .{ .process = process, .input = in_w, .output = out_r, .console = pc, .sink = sink };
    try p.watch();
}

/// Starts `argv` with pipes for its input and its output (stderr merged
/// into stdout when `merge_stderr`, else into `stderr_fd` if given), in `cwd`.
pub fn spawnPipes(p: *Process, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: ?[*:0]const u8, merge_stderr: bool, sink: Sink) !void {
    return spawnPipesErr(p, argv, envp, cwd, merge_stderr, null, sink);
}

pub fn spawnPipesErr(p: *Process, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: ?[*:0]const u8, merge_stderr: bool, stderr_fd: ?Fd, sink: Sink) !void {
    const in = try pipe(true);
    const out = pipe(false) catch |e| {
        _ = CloseHandle(in[0]);
        _ = CloseHandle(in[1]);
        return e;
    };
    // Without a stderr of its own, the child's goes to its output too
    // (nothing else would read it).
    const err = if (merge_stderr) out[1] else stderr_fd orelse out[1];
    var inherit: [3]HANDLE = .{ in[0], out[1], err };
    const n: usize = if (err == out[1]) 2 else 3;
    const process = create(argv, envp, cwd, &.{.{ .id = ATTR_HANDLE_LIST, .value = &inherit, .size = n * @sizeOf(HANDLE) }}, .{ in[0], out[1], err });
    _ = CloseHandle(in[0]);
    _ = CloseHandle(out[1]);
    const ph = process catch |e| {
        _ = CloseHandle(in[1]);
        _ = CloseHandle(out[0]);
        return e;
    };
    p.* = .{ .process = ph, .input = in[1], .output = out[0], .sink = sink };
    try p.watch();
}

/// A pipe whose read end is watched: what a process writes to the write
/// end (its stderr) is kept, the last `cap` bytes.
pub const Tail = struct {
    gpa: std.mem.Allocator,
    read_fd: ?HANDLE = null,
    write_fd: ?HANDLE = null,
    bytes: std.ArrayList(u8) = .empty,
    watch_: ?fdwatch.Watch = null,
    const cap = 4096;

    pub fn open(t: *Tail) !void {
        const fds = try pipe(false);
        t.read_fd = fds[0];
        t.write_fd = fds[1];
        t.watch_ = try fdwatch.reader(fds[0], t, onBytes, onEnd);
    }

    /// After the child started: only the child keeps the write end.
    pub fn closeWriteEnd(t: *Tail) void {
        if (t.write_fd) |h| _ = CloseHandle(h);
        t.write_fd = null;
    }

    fn onBytes(ctx: ?*anyopaque, b: []const u8) void {
        const t: *Tail = @ptrCast(@alignCast(ctx));
        t.bytes.appendSlice(t.gpa, b) catch return;
        if (t.bytes.items.len > cap) {
            const drop = t.bytes.items.len - cap;
            std.mem.copyForwards(u8, t.bytes.items[0..cap], t.bytes.items[drop..]);
            t.bytes.items.len = cap;
        }
    }

    fn onEnd(_: ?*anyopaque) callconv(.c) void {}

    /// The last non-empty line written, if any.
    pub fn lastLine(t: *const Tail) []const u8 {
        var it = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, t.bytes.items, " \n\r"), '\n');
        while (it.next()) |l| if (std.mem.trim(u8, l, " \r").len > 0) return std.mem.trim(u8, l, " \r");
        return "";
    }

    pub fn deinit(t: *Tail) void {
        if (t.watch_) |w| w.cancel();
        if (t.read_fd) |h| _ = CloseHandle(h);
        t.closeWriteEnd();
        t.bytes.deinit(t.gpa);
    }
};

test "command lines read back as the arguments given" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try proc.cStrings(a, &.{ "C:\\Program Files\\graff.exe", "login", "say \"hi\"", "trail\\", "" });
    try std.testing.expectEqualStrings("\"C:\\Program Files\\graff.exe\" login \"say \\\"hi\\\"\" trail\\ \"\"", try commandLine(a, argv));
    const npx = try proc.cStrings(a, &.{ "C:\\nodejs\\npx.cmd", "-y", "pkg" });
    try std.testing.expectEqualStrings("cmd.exe /d /s /c \"C:\\nodejs\\npx.cmd -y pkg\"", try commandLine(a, npx));
}
