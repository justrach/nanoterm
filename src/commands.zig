//! The commands the shell knows: every program on PATH, zsh's builtins
//! and keywords. The input classifier asks it whether a word is a command,
//! and completion offers its names.
const std = @import("std");

pub const builtins = [_][]const u8{
    "alias",  "bg",     "bindkey", "builtin", "cd",      "command", "declare", "dirs",   "disown",
    "echo",   "eval",   "exec",    "exit",    "export",  "fc",      "fg",      "functions", "hash",
    "history", "jobs",  "kill",    "let",     "local",   "popd",    "print",   "printf", "pushd",
    "pwd",    "read",   "readonly", "return", "set",     "setopt",  "shift",   "source", "test",
    "time",   "trap",   "type",    "typeset", "ulimit",  "umask",   "unalias", "unset",  "unsetopt",
    "wait",   "whence", "where",   "which",   "for",     "while",   "if",      "case",   "until",
    "repeat", "select", "function", "sudo",   "noglob",  "nocorrect", "exec",  "clear",  "z",
};

pub const Commands = struct {
    gpa: std.mem.Allocator,
    names: std.StringHashMapUnmanaged(void) = .empty,
    /// The names, sorted, for completion.
    sorted: std.ArrayList([]const u8) = .empty,
    /// The names' memory.
    arena: std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) Commands {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(c: *Commands) void {
        c.names.deinit(c.gpa);
        c.sorted.deinit(c.gpa);
        c.arena.deinit();
    }

    pub fn add(c: *Commands, name: []const u8) void {
        if (name.len == 0 or name[0] == '.' or c.names.contains(name)) return;
        const own = c.arena.allocator().dupe(u8, name) catch return;
        c.names.put(c.gpa, own, {}) catch return;
        c.sorted.append(c.gpa, own) catch {};
    }

    /// Reads the programs of every PATH directory, and the builtins.
    pub fn scan(c: *Commands, io: std.Io, path_env: []const u8) void {
        for (builtins) |b| c.add(b);
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |dir_path| {
            if (dir_path.len == 0) continue;
            var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var entries = dir.iterate();
            while (entries.next(io) catch null) |e| {
                if (e.kind == .file or e.kind == .sym_link) c.add(e.name);
            }
        }
        std.mem.sort([]const u8, c.sorted.items, {}, lessThan);
    }

    fn lessThan(_: void, a: []const u8, b: []const u8) bool {
        return std.mem.order(u8, a, b) == .lt;
    }

    pub fn has(c: *const Commands, name: []const u8) bool {
        return c.names.contains(name);
    }

    /// The names starting with `prefix`, in order.
    pub fn withPrefix(c: *const Commands, prefix: []const u8) []const []const u8 {
        const items = c.sorted.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (std.mem.order(u8, items[mid], prefix) == .lt) lo = mid + 1 else hi = mid;
        }
        var end = lo;
        while (end < items.len and std.mem.startsWith(u8, items[end], prefix)) end += 1;
        return items[lo..end];
    }
};

/// git's everyday subcommands, offered after `git `.
pub const git_subcommands = [_][]const u8{
    "add",    "bisect", "blame",  "branch", "checkout", "cherry-pick", "clone", "commit", "diff",
    "fetch",  "grep",   "init",   "log",    "merge",    "mv",          "pull",  "push",   "rebase",
    "reflog", "remote", "reset",  "restore", "revert",  "rm",          "show",  "stash",  "status",
    "switch", "tag",    "worktree",
};

/// git subcommands whose next word is a branch.
pub fn takesBranch(sub: []const u8) bool {
    const list = [_][]const u8{ "checkout", "switch", "merge", "rebase", "branch", "diff", "log", "reset", "cherry-pick", "push", "pull" };
    for (list) |s| if (std.mem.eql(u8, s, sub)) return true;
    return false;
}

test "commands by prefix" {
    var c: Commands = .init(std.testing.allocator);
    defer c.deinit();
    for ([_][]const u8{ "git", "gzip", "grep", "ls", "go" }) |n| c.add(n);
    std.mem.sort([]const u8, c.sorted.items, {}, Commands.lessThan);
    try std.testing.expect(c.has("git"));
    try std.testing.expect(!c.has("gi"));
    const g = c.withPrefix("g");
    try std.testing.expectEqual(@as(usize, 4), g.len);
    try std.testing.expectEqualStrings("git", g[0]);
    try std.testing.expectEqual(@as(usize, 0), c.withPrefix("x").len);
}
