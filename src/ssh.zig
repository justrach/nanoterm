//! SSH as nanoterm does it. An interactive `ssh host` you run opens a
//! shared connection (ControlMaster, in a directory only you can open), so
//! once you have signed in, the agent's commands on that host reuse it,
//! without a password or a prompt. A line of setup sent to the remote shell
//! (for this session only; nothing is written there) makes it mark its
//! prompts as nanoterm's own zsh does, tagged `;r`: each remote command is
//! then a block, with its status and the remote folder.
const std = @import("std");

/// How long a shared connection outlives its last user.
const persist = "10m";

/// Options taking an argument, from ssh(1).
const with_arg = "BbcDEeFIiJLlmOoPpQRSWw";

/// What an `ssh` command line is: its destination, and whether it opens a
/// shell (no remote command after the destination).
pub const Target = struct {
    /// The destination as written (`user@host`, an alias).
    dest: []const u8,
    interactive: bool,
};

pub fn parse(command: []const u8) ?Target {
    var it = std.mem.tokenizeAny(u8, command, " \t");
    const first = it.next() orelse return null;
    if (!std.mem.eql(u8, first, "ssh")) return null;
    while (it.next()) |w| {
        if (w.len > 1 and w[0] == '-') {
            // `-p 22`: its argument follows unless it is attached (`-p22`).
            const last = w[w.len - 1];
            if (w.len == 2 and std.mem.indexOfScalar(u8, with_arg, last) != null) _ = it.next();
            continue;
        }
        return .{ .dest = w, .interactive = it.next() == null };
    }
    return null;
}

/// The host part of a destination (`user@host:22` → `host`).
pub fn host(dest: []const u8) []const u8 {
    const at = if (std.mem.lastIndexOfScalar(u8, dest, '@')) |i| dest[i + 1 ..] else dest;
    return at[0 .. std.mem.indexOfScalar(u8, at, ':') orelse at.len];
}

/// The directory of shared connections: short (socket paths are limited
/// to about 100 bytes) and the user's own.
pub fn controlDir(buf: []u8, uid: u32) []const u8 {
    return std.fmt.bufPrint(buf, "/tmp/nanoterm-ssh-{d}", .{uid}) catch "/tmp/nanoterm-ssh";
}

extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
const getuid = if (@import("builtin").os.tag == .windows) struct {
    // One user's folder on Windows: the temporary one is already theirs.
    fn f() c_uint {
        return 0;
    }
}.f else struct {
    extern "c" fn getuid() c_uint;
}.getuid;

/// The directory of shared connections, made (only the user may open it).
pub fn ensureDir(buf: []u8) []const u8 {
    const dir = controlDir(buf[0 .. buf.len - 1], getuid());
    buf[dir.len] = 0;
    _ = mkdir(buf[0..dir.len :0], 0o700);
    return dir;
}

/// `ssh …` with the connection shared: options right after `ssh`.
pub fn shared(arena: std.mem.Allocator, command: []const u8, dir: []const u8) ![]const u8 {
    // Windows' OpenSSH can't share connections.
    if (@import("builtin").os.tag == .windows) return command;
    const rest = std.mem.trimStart(u8, command[3..], " ");
    return std.fmt.allocPrint(arena, "ssh -o ControlMaster=auto -o ControlPath={s}/%C -o ControlPersist={s} {s}", .{ dir, persist, rest });
}

/// A command for the agent on the host of `session` (the `ssh …` that
/// opened it): through its shared connection, never asking for anything,
/// in `cwd`.
pub fn remoteCommand(arena: std.mem.Allocator, session: []const u8, dir: []const u8, cwd: []const u8, command: []const u8) ![]const u8 {
    const rest = std.mem.trimStart(u8, session[3..], " ");
    const inner = if (cwd.len > 0) try std.fmt.allocPrint(arena, "cd {s} && {s}", .{ try quote(arena, cwd), command }) else command;
    return std.fmt.allocPrint(arena, "ssh -o ControlPath={s}/%C -o BatchMode=yes {s} -- {s}", .{ dir, rest, try quote(arena, inner) });
}

/// `s` in single quotes for a POSIX shell.
pub fn quote(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (s) |ch| {
        if (ch == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, ch);
    }
    try out.append(arena, '\'');
    return out.items;
}

/// The setup line for the remote shell (bash, zsh): an empty prompt (the
/// input is nanoterm's), and marks before each command, after it with its
/// status, and with the folder. Starts with a space: kept out of history
/// where the shell ignores such lines.
pub const setup =
    " PS1='' PS2=''; __nt_p(){ local s=$?; printf '\\033]133;D;%s;r\\007\\033]7;file://%s%s\\007\\033]133;A;r\\007' \"$s\" \"${HOSTNAME:-$(hostname)}\" \"$PWD\"; };" ++
    " if [ -n \"$ZSH_VERSION\" ]; then __nt_x(){ printf '\\033]133;C;r\\007'; }; precmd_functions+=(__nt_p); preexec_functions+=(__nt_x); PROMPT='' RPROMPT='';" ++
    " elif [ -n \"$BASH_VERSION\" ]; then __nt_r=1; __nt_x(){ [ -n \"$__nt_r\" ] && { __nt_r=; printf '\\033]133;C;r\\007'; }; }; trap '__nt_x' DEBUG; PROMPT_COMMAND='__nt_p; __nt_r=1'; fi\n";

/// The hosts of `~/.ssh/config` (its `Host` names, not patterns).
pub fn hosts(arena: std.mem.Allocator, io: std.Io, home: []const u8) []const []const u8 {
    const path = std.fs.path.join(arena, &.{ home, ".ssh", "config" }) catch return &.{};
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, data, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len < 5 or !std.ascii.eqlIgnoreCase(line[0..4], "host") or (line[4] != ' ' and line[4] != '\t' and line[4] != '=')) continue;
        var names = std.mem.tokenizeAny(u8, line[5..], " \t=");
        while (names.next()) |n| {
            if (std.mem.indexOfAny(u8, n, "*?!") != null) continue;
            out.append(arena, n) catch {};
        }
    }
    return out.items;
}

test "ssh command lines" {
    const a = parse("ssh -p 2222 -i ~/.ssh/k me@box").?;
    try std.testing.expectEqualStrings("me@box", a.dest);
    try std.testing.expect(a.interactive);
    try std.testing.expect(!parse("ssh box uptime").?.interactive);
    try std.testing.expect(parse("sshfs box:/ m") == null);
    try std.testing.expectEqualStrings("box", host("me@box:22"));
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const s = try shared(arena.allocator(), "ssh -p 2222 me@box", "/tmp/x");
    try std.testing.expectEqualStrings("ssh -o ControlMaster=auto -o ControlPath=/tmp/x/%C -o ControlPersist=10m -p 2222 me@box", s);
    const r = try remoteCommand(arena.allocator(), "ssh -p 2222 me@box", "/tmp/x", "/srv/app", "ls -la 'a b'");
    try std.testing.expectEqualStrings("ssh -o ControlPath=/tmp/x/%C -o BatchMode=yes -p 2222 me@box -- 'cd '\\''/srv/app'\\'' && ls -la '\\''a b'\\'''", r);
}
