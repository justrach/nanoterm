//! The user's shell (zsh) on a pseudo-terminal, cut into blocks. A small
//! rc file sources the user's own, then adds hooks that mark the prompt
//! (OSC 133;A), the start of a command's output (133;C), its end with the
//! exit status (133;D), and the working directory (OSC 7). Output between
//! C and D is the block's; the prompt and the echo of the command are not.
const std = @import("std");
const proc = @import("proc.zig");
const vt = @import("vt.zig");
const blocks = @import("blocks.zig");

const integration =
    \\# nanoterm's shell integration: the user's rc first, then the marks.
    \\if [[ -f "$NANOTERM_USER_ZDOTDIR/.zshrc" ]]; then
    \\  ZDOTDIR="$NANOTERM_USER_ZDOTDIR" source "$NANOTERM_USER_ZDOTDIR/.zshrc"
    \\fi
    \\ZDOTDIR="$NANOTERM_ZDOTDIR"
    \\unsetopt PROMPT_SP PROMPT_CR 2>/dev/null
    \\_nanoterm_precmd() {
    \\  local s=$?
    \\  printf '\e]133;D;%s\a\e]7;file://%s%s\a' "$s" "$HOST" "$PWD"
    \\  PROMPT='' RPROMPT='' PS2=''
    \\  printf '\e]133;A\a'
    \\}
    \\_nanoterm_preexec() { printf '\e]133;C\a'; }
    \\precmd_functions+=(_nanoterm_precmd)
    \\preexec_functions+=(_nanoterm_preexec)
    \\
;

const env_rc =
    \\[[ -f "$NANOTERM_USER_ZDOTDIR/.zshenv" ]] && ZDOTDIR="$NANOTERM_USER_ZDOTDIR" source "$NANOTERM_USER_ZDOTDIR/.zshenv"
    \\ZDOTDIR="$NANOTERM_ZDOTDIR"
    \\
;

pub const Phase = enum {
    /// Starting: the user's rc runs, before the first prompt.
    starting,
    /// At the prompt: ready for a command.
    ready,
    /// A command runs: its output goes to the current block.
    running,
    /// Between a command's end and the next prompt.
    between,
};

/// An SSH session running in the shell (the block of `ssh host`), and,
/// once its shell is set up, the remote command running as its own block.
pub const Remote = struct {
    session: *blocks.Block,
    /// The `ssh …` written, for the agent's commands on the host.
    command: []u8,
    host: []u8,
    /// The remote shell marks its prompts: each command is a block.
    active: bool = false,
    /// The setup line was sent: its echo is not shown.
    hiding: bool = false,
    phase: Phase = .ready,
    current: ?*blocks.Block = null,
    cwd: std.ArrayList(u8) = .empty,
};

pub const Events = struct {
    ctx: *anyopaque,
    /// Something changed: draw again.
    changed: *const fn (ctx: *anyopaque) void,
    /// The shell itself ended.
    exited: *const fn (ctx: *anyopaque, code: i32) void,
};

pub const Shell = struct {
    gpa: std.mem.Allocator,
    process: proc.Process = undefined,
    phase: Phase = .starting,
    events: Events,
    cwd: std.ArrayList(u8) = .empty,
    /// The block of the command running, if any.
    current: ?*blocks.Block = null,
    /// Bytes of an OSC sequence split across reads.
    pending: std.ArrayList(u8) = .empty,
    /// Where bytes outside a command go: discarded, but parsed so that
    /// escape sequences split across reads stay whole.
    discard: vt.Output,
    alive: bool = false,
    /// An SSH session, while one runs.
    remote: ?Remote = null,
    /// The terminal's size.
    cols: u16 = 100,
    rows: u16 = 40,

    pub fn init(gpa: std.mem.Allocator, events: Events) Shell {
        return .{ .gpa = gpa, .events = events, .discard = .init(gpa) };
    }

    pub fn deinit(s: *Shell) void {
        if (s.alive) s.process.close();
        s.cwd.deinit(s.gpa);
        s.pending.deinit(s.gpa);
        s.discard.deinit();
        s.endRemote(0);
    }

    /// Starts zsh in `cwd` with the integration in `zdotdir` (a directory
    /// of nanoterm's own), `env` being the environment to pass.
    pub fn start(s: *Shell, arena: std.mem.Allocator, io: std.Io, zdotdir: []const u8, home: []const u8, env: *std.process.Environ.Map, cwd: []const u8, size: proc.Winsize) !void {
        const dir = std.Io.Dir.cwd();
        try dir.createDirPath(io, zdotdir);
        const rc_path = try std.fs.path.join(arena, &.{ zdotdir, ".zshrc" });
        try dir.writeFile(io, .{ .sub_path = rc_path, .data = integration });
        const env_path = try std.fs.path.join(arena, &.{ zdotdir, ".zshenv" });
        try dir.writeFile(io, .{ .sub_path = env_path, .data = env_rc });

        try env.put("NANOTERM_USER_ZDOTDIR", env.get("ZDOTDIR") orelse home);
        try env.put("NANOTERM_ZDOTDIR", zdotdir);
        try env.put("ZDOTDIR", zdotdir);
        try env.put("TERM", "xterm-256color");
        try env.put("COLORTERM", "truecolor");
        try env.put("TERM_PROGRAM", "nanoterm");
        try env.put("CLICOLOR", "1");
        // Pagers would take the screen: blocks show their text instead.
        try env.put("PAGER", "cat");
        try env.put("GIT_PAGER", "cat");
        try env.put("MANPAGER", "cat");
        // Start where asked: zsh begins in its own working directory.
        try env.put("PWD", cwd);

        var items: std.ArrayList([]const u8) = .empty;
        var it = env.iterator();
        while (it.next()) |e| try items.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }));
        const envp = try proc.cStrings(arena, items.items);
        const argv = try proc.cStrings(arena, &.{ "/bin/zsh", "-i" });
        try s.cwd.appendSlice(s.gpa, cwd);
        const cwd_z = try arena.dupeSentinel(u8, cwd, 0);
        s.cols = size.cols;
        s.rows = size.rows;
        try proc.spawnPty(&s.process, argv, envp, cwd_z, size, .{ .ctx = s, .output = onOutput, .exited = onExited });
        s.alive = true;
    }

    /// Runs `command` as a new block; while a command runs, sends it to
    /// that command's input instead. Returns the block made, if any.
    pub fn submit(s: *Shell, block: *blocks.Block) void {
        s.current = block;
        // A full-screen program draws at the terminal's size and asks it
        // questions (where the cursor is, its colors).
        block.output.resize(s.cols, s.rows);
        block.output.reply = .{ .ctx = s, .func = reply };
        s.process.send(block.command);
        s.process.send("\n");
    }

    /// Runs `block`, sending `text` (its command as the shell gets it).
    pub fn submitAs(s: *Shell, block: *blocks.Block, text: []const u8) void {
        s.current = block;
        block.output.resize(s.cols, s.rows);
        block.output.reply = .{ .ctx = s, .func = reply };
        s.process.send(text);
        s.process.send("\n");
    }

    /// The block `session` is an SSH session to `host`, opened by `command`.
    pub fn startRemote(s: *Shell, session: *blocks.Block, command: []const u8, host: []const u8) void {
        s.endRemote(0);
        const cmd = s.gpa.dupe(u8, command) catch return;
        const h = s.gpa.dupe(u8, host) catch {
            s.gpa.free(cmd);
            return;
        };
        s.remote = .{ .session = session, .command = cmd, .host = h };
    }

    fn endRemote(s: *Shell, code: i32) void {
        var r = s.remote orelse return;
        if (r.current) |b| b.finish(code);
        s.gpa.free(r.command);
        s.gpa.free(r.host);
        r.cwd.deinit(s.gpa);
        s.remote = null;
    }

    /// Sends the remote shell the setup line: blocks from then on.
    pub fn setUpRemote(s: *Shell) void {
        const r = &(s.remote orelse return);
        if (r.active) return;
        r.hiding = true;
        s.process.send(@import("ssh.zig").setup);
    }

    /// Whether a command typed now runs on the host as its own block.
    pub fn remoteReady(s: *const Shell) bool {
        const r = s.remote orelse return false;
        return r.active and r.current == null and s.current == r.session;
    }

    /// Runs `block` on the host.
    pub fn submitRemote(s: *Shell, block: *blocks.Block) void {
        const r = &(s.remote orelse return);
        r.current = block;
        block.output.resize(s.cols, s.rows);
        block.output.reply = .{ .ctx = s, .func = reply };
        s.process.send(block.command);
        s.process.send("\n");
    }

    /// Text typed while a command runs: its input.
    pub fn input(s: *Shell, text: []const u8) void {
        s.process.send(text);
    }

    pub fn interrupt(s: *Shell) void {
        // ^C through the terminal: the foreground job gets SIGINT.
        s.process.send("\x03");
    }

    pub fn resize(s: *Shell, rows: u16, cols: u16) void {
        s.cols = cols;
        s.rows = rows;
        if (s.current) |b| b.output.resize(cols, rows);
        if (s.alive) s.process.resize(rows, cols);
    }

    fn reply(ctx: *anyopaque, bytes: []const u8) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        if (s.alive) s.process.send(bytes);
    }

    /// The screen of the full-screen program running, if one is.
    pub fn fullScreen(s: *const Shell) ?*@import("screen.zig").Screen {
        const b = s.current orelse return null;
        const f = b.output.full orelse return null;
        return f.screen;
    }

    pub fn busy(s: *const Shell) bool {
        return s.current != null;
    }

    fn onOutput(ctx: *anyopaque, bytes: []const u8) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.route(bytes) catch {};
        s.events.changed(s.events.ctx);
    }

    fn onExited(ctx: *anyopaque, code: i32) void {
        const s: *Shell = @ptrCast(@alignCast(ctx));
        s.endRemote(code);
        if (s.current) |b| b.finish(code);
        s.current = null;
        s.events.exited(s.events.ctx, code);
    }

    fn target(s: *Shell) *vt.Output {
        // In a set-up SSH session: the remote command's block, else nowhere
        // (the remote prompt, the echo of what was typed).
        if (s.remote) |*r| if (s.phase == .running and s.current == r.session) {
            if (r.hiding) return &s.discard;
            if (r.active) return if (r.phase == .running) if (r.current) |b| &b.output else &s.discard else &s.discard;
        };
        if (s.phase == .running) if (s.current) |b| return &b.output;
        return &s.discard;
    }

    /// Splits `bytes` at the shell's marks, sending each part where it goes.
    fn route(s: *Shell, bytes: []const u8) !void {
        var begin: usize = 0;
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            if (s.pending.items.len > 0) {
                try s.pending.append(s.gpa, bytes[i]);
                const p = s.pending.items;
                if (p.len == 2 and p[1] != ']') {
                    try s.target().feed(p);
                    s.pending.clearRetainingCapacity();
                } else if (p.len > 2 and (p[p.len - 1] == 0x07 or (p[p.len - 1] == '\\' and p[p.len - 2] == 0x1b))) {
                    const end: usize = if (p[p.len - 1] == 0x07) 1 else 2;
                    const payload = p[2 .. p.len - end];
                    if (!s.mark(payload)) try s.target().feed(p);
                    s.pending.clearRetainingCapacity();
                } else if (p.len > 4096) {
                    try s.target().feed(p);
                    s.pending.clearRetainingCapacity();
                }
                begin = i + 1;
                continue;
            }
            if (bytes[i] == 0x1b) {
                if (i > begin) try s.target().feed(bytes[begin..i]);
                try s.pending.append(s.gpa, 0x1b);
                begin = i + 1;
            }
        }
        if (begin < bytes.len and s.pending.items.len == 0) try s.target().feed(bytes[begin..]);
    }

    /// Handles an OSC mark of the integration; false for other OSCs.
    fn mark(s: *Shell, payload: []const u8) bool {
        if (std.mem.startsWith(u8, payload, "133;")) {
            const rest = payload[4..];
            if (rest.len == 0) return true;
            // The remote shell's marks.
            if (std.mem.endsWith(u8, rest, ";r")) {
                const r = &(s.remote orelse return true);
                switch (rest[0]) {
                    'A' => {
                        r.active = true;
                        r.hiding = false;
                        r.phase = .ready;
                        s.discard.clear();
                    },
                    'C' => r.phase = .running,
                    'D' => {
                        const code = if (rest.len > 4) std.fmt.parseInt(i32, rest[2 .. rest.len - 2], 10) catch 0 else 0;
                        if (r.current) |b| b.finish(code);
                        r.current = null;
                        r.phase = .between;
                    },
                    else => {},
                }
                return true;
            }
            switch (rest[0]) {
                'A' => {
                    s.phase = .ready;
                    s.discard.clear();
                },
                'C' => s.phase = .running,
                'D' => {
                    const code = if (rest.len > 2) std.fmt.parseInt(i32, rest[2..], 10) catch 0 else 0;
                    // The SSH session ended: so did what ran in it.
                    if (s.remote) |r| if (s.current == r.session) s.endRemote(code);
                    if (s.current) |b| b.finish(code);
                    s.current = null;
                    s.phase = .between;
                },
                else => {},
            }
            return true;
        }
        if (std.mem.startsWith(u8, payload, "7;file://")) {
            const rest = payload["7;file://".len..];
            const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return true;
            // The remote folder, while the session runs.
            if (s.remote) |*r| if (s.current == r.session) {
                r.cwd.clearRetainingCapacity();
                r.cwd.appendSlice(s.gpa, rest[slash..]) catch {};
                return true;
            };
            s.cwd.clearRetainingCapacity();
            s.cwd.appendSlice(s.gpa, rest[slash..]) catch {};
            return true;
        }
        return false;
    }
};
