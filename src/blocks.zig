//! Blocks, as Warp has them: a command, where it ran, its output, how it
//! ended. The shell's commands and the commands an agent runs are both
//! blocks; agent turns hold the agent's side of a conversation.
const std = @import("std");
const vt = @import("vt.zig");

pub fn now() f64 {
    return @import("nanoui").ui.clock.now();
}

pub const Source = enum {
    /// Typed by the user, run by their shell.
    shell,
    /// Run for an agent (ACP `terminal/create`), outside the shell.
    agent,
};

pub const State = enum { running, done };

pub const Block = struct {
    id: u64,
    source: Source,
    command: []u8,
    cwd: []u8,
    git_branch: []u8,
    output: vt.Output,
    state: State = .running,
    exit_code: ?i32 = null,
    started: f64,
    ended: f64 = 0,
    /// Showing all the output, past the last lines shown by default.
    expanded: bool = false,
    /// Markdown printed by `cat`, shown as the text it was (not rendered).
    raw: bool = false,

    pub fn create(gpa: std.mem.Allocator, id: u64, source: Source, command: []const u8, cwd: []const u8, branch: []const u8) !*Block {
        const b = try gpa.create(Block);
        errdefer gpa.destroy(b);
        b.* = .{
            .id = id,
            .source = source,
            .command = try gpa.dupe(u8, command),
            .cwd = try gpa.dupe(u8, cwd),
            .git_branch = try gpa.dupe(u8, branch),
            .output = .init(gpa),
            .started = now(),
        };
        return b;
    }

    pub fn destroy(b: *Block, gpa: std.mem.Allocator) void {
        gpa.free(b.command);
        gpa.free(b.cwd);
        gpa.free(b.git_branch);
        b.output.deinit();
        gpa.destroy(b);
    }

    pub fn finish(b: *Block, code: i32) void {
        if (b.state == .done) return;
        b.state = .done;
        // A program that ended on its screen leaves it.
        b.output.leaveScreen();
        b.exit_code = code;
        b.ended = now();
    }

    pub fn seconds(b: *const Block) f64 {
        return (if (b.state == .done) b.ended else now()) - b.started;
    }

    pub fn failed(b: *const Block) bool {
        return b.state == .done and (b.exit_code orelse 0) != 0;
    }
};

/// The Markdown file a command prints whole, as `cat README.md` does; null
/// for any other command (several files, flags, pipes, redirections).
pub fn markdownFile(command: []const u8) ?[]const u8 {
    if (std.mem.indexOfAny(u8, command, "|<>;&`$(") != null) return null;
    var it = std.mem.tokenizeAny(u8, command, " \t");
    const prog = it.next() orelse return null;
    if (!std.mem.eql(u8, prog, "cat")) return null;
    const arg = it.next() orelse return null;
    if (it.next() != null or arg[0] == '-') return null;
    const path = std.mem.trim(u8, arg, "'\"");
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".md", ".markdown", ".mdx" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return path;
    return null;
}

test "markdown printed by cat" {
    try std.testing.expectEqualStrings("AGENTS.md", markdownFile("cat AGENTS.md").?);
    try std.testing.expectEqualStrings("docs/notes.MD", markdownFile("cat 'docs/notes.MD'").?);
    try std.testing.expectEqualStrings("a.markdown", markdownFile("  cat   a.markdown ").?);
    try std.testing.expect(markdownFile("cat main.zig") == null);
    try std.testing.expect(markdownFile("cat -n README.md") == null);
    try std.testing.expect(markdownFile("cat a.md b.md") == null);
    try std.testing.expect(markdownFile("cat README.md | head") == null);
    try std.testing.expect(markdownFile("bat README.md") == null);
}

/// `path` with the home directory shown as `~`, in `arena`.
pub fn tildePath(arena: std.mem.Allocator, path: []const u8, home: []const u8) []const u8 {
    if (home.len > 0 and std.mem.startsWith(u8, path, home)) {
        return std.fmt.allocPrint(arena, "~{s}", .{path[home.len..]}) catch path;
    }
    return path;
}

/// The git branch checked out at `dir` or above it, or "" outside a
/// repository: read from `.git/HEAD`, no git process.
pub fn gitBranch(io: std.Io, buf: []u8, dir: []const u8) []const u8 {
    var d = dir;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (d.len > 0) {
        const head = std.fmt.bufPrint(&path_buf, "{s}/.git/HEAD", .{d}) catch return "";
        var file_buf: [256]u8 = undefined;
        if (std.Io.Dir.cwd().readFile(io, head, &file_buf)) |data| {
            const s = std.mem.trim(u8, data, " \n\r");
            const prefix = "ref: refs/heads/";
            const name = if (std.mem.startsWith(u8, s, prefix)) s[prefix.len..] else s[0..@min(s.len, 7)];
            const n = @min(name.len, buf.len);
            @memcpy(buf[0..n], name[0..n]);
            return buf[0..n];
        } else |_| {}
        const parent = std.fs.path.dirname(d) orelse return "";
        if (parent.len == d.len) return "";
        d = parent;
    }
    return "";
}
