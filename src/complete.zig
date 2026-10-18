//! Completions, as Warp's menu offers them: Tab completes the word being
//! typed — commands, files and folders, git's subcommands and branches —
//! and in agent mode "/" lists the agent's slash commands. One candidate
//! is taken at once; several open a menu (↑↓ to choose, Tab or ↩ to take).
const std = @import("std");
const Commands = @import("commands.zig");
const agent_config = @import("agent_config.zig");

pub const Kind = enum { command, folder, file, git, branch, slash };

pub const Item = struct {
    /// The word as it replaces the one typed.
    word: []const u8,
    /// A description: a slash command's, or what kind of thing it is.
    detail: []const u8 = "",
    kind: Kind,
};

/// The completions of one word, in memory that lives until the next ones.
pub const Menu = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Item) = .empty,
    /// Bytes [start, end) of the input are the word being completed.
    start: usize = 0,
    end: usize = 0,
    selected: usize = 0,
    open: bool = false,
    /// Closed with esc: it stays closed until the text changes.
    dismissed: bool = false,

    pub fn init(gpa: std.mem.Allocator) Menu {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(m: *Menu) void {
        m.items.deinit(m.gpa);
        m.arena.deinit();
    }

    pub fn close(m: *Menu) void {
        m.open = false;
        m.items.clearRetainingCapacity();
        _ = m.arena.reset(.retain_capacity);
        m.selected = 0;
    }

    fn add(m: *Menu, word: []const u8, detail: []const u8, kind: Kind) void {
        if (m.items.items.len >= max_items) return;
        const own = m.arena.allocator().dupe(u8, word) catch return;
        m.items.append(m.gpa, .{ .word = own, .detail = detail, .kind = kind }) catch {};
    }

    pub fn move(m: *Menu, by: i32) void {
        const n = m.items.items.len;
        if (n == 0) return;
        const i: i64 = @as(i64, @intCast(m.selected)) + by;
        m.selected = @intCast(@mod(i, @as(i64, @intCast(n))));
    }

    /// The longest start the candidates share.
    pub fn commonPrefix(m: *const Menu) []const u8 {
        const items = m.items.items;
        if (items.len == 0) return "";
        var p = items[0].word;
        for (items[1..]) |it| {
            var n: usize = 0;
            while (n < p.len and n < it.word.len and p[n] == it.word[n]) n += 1;
            p = p[0..n];
        }
        return p;
    }
};

const max_items = 200;

pub const Context = struct {
    io: std.Io,
    cwd: []const u8,
    home: []const u8,
    commands: *const Commands.Commands,
    /// The agent's slash commands, in agent mode.
    slash: ?[]const agent_config.Command = null,
};

/// Fills `m` with the completions of the word ending at `caret` in `text`.
pub fn compute(m: *Menu, text: []const u8, caret: usize, ctx: Context) void {
    m.close();
    const upto = text[0..@min(caret, text.len)];
    const start = if (std.mem.lastIndexOfScalar(u8, upto, ' ')) |i| i + 1 else 0;
    const word = upto[start..];
    m.start = start;
    m.end = upto.len;
    var words: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, upto[0..start], ' ');
    while (it.next()) |w| {
        if (n == words.len) break;
        words[n] = w;
        n += 1;
    }
    if (ctx.slash) |cmds| if (n == 0 and word.len > 0 and word[0] == '/') {
        for (cmds) |c| if (std.mem.startsWith(u8, c.name, word[1..])) {
            var buf: [128]u8 = undefined;
            m.add(std.fmt.bufPrint(&buf, "/{s}", .{c.name}) catch continue, c.description, .slash);
        };
        return;
    };
    if (n == 0) {
        if (word.len == 0 or std.mem.indexOfScalar(u8, word, '/') != null) return paths(m, word, ctx);
        for (ctx.commands.withPrefix(word)) |c| m.add(c, "", .command);
        return;
    }
    if (word.len > 0 and word[0] == '-') return;
    if (std.mem.eql(u8, words[0], "git")) {
        if (n == 1) {
            for (Commands.git_subcommands) |s| if (std.mem.startsWith(u8, s, word)) m.add(s, "", .git);
            return;
        }
        if (n == 2 and Commands.takesBranch(words[1])) {
            branches(m, word, ctx);
            if (m.items.items.len > 0) return;
        }
    }
    paths(m, word, ctx);
}

/// Files and folders: `word` is a path, absolute, from ~, or from the cwd.
fn paths(m: *Menu, word: []const u8, ctx: Context) void {
    const slash = std.mem.lastIndexOfScalar(u8, word, '/');
    const dir_part = if (slash) |i| word[0 .. i + 1] else "";
    const base = if (slash) |i| word[i + 1 ..] else word;
    var buf: [2048]u8 = undefined;
    const dir_path = if (std.mem.startsWith(u8, dir_part, "~/"))
        std.fmt.bufPrint(&buf, "{s}/{s}", .{ ctx.home, dir_part[2..] }) catch return
    else if (dir_part.len > 0 and dir_part[0] == '/')
        dir_part
    else
        std.fmt.bufPrint(&buf, "{s}/{s}", .{ ctx.cwd, dir_part }) catch return;
    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(ctx.io);
    var entries = dir.iterate();
    while (entries.next(ctx.io) catch null) |e| {
        if (!std.mem.startsWith(u8, e.name, base)) continue;
        if (e.name[0] == '.' and (base.len == 0 or base[0] != '.')) continue;
        var wbuf: [2048]u8 = undefined;
        const folder = e.kind == .directory;
        const full = std.fmt.bufPrint(&wbuf, "{s}{s}{s}", .{ dir_part, e.name, if (folder) "/" else "" }) catch continue;
        m.add(full, "", if (folder) .folder else .file);
    }
    std.mem.sort(Item, m.items.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            // Folders first, then by name.
            if ((a.kind == .folder) != (b.kind == .folder)) return a.kind == .folder;
            return std.mem.order(u8, a.word, b.word) == .lt;
        }
    }.lt);
}

/// Local branches, from the repository's refs (no git process).
fn branches(m: *Menu, word: []const u8, ctx: Context) void {
    var dir_buf: [2048]u8 = undefined;
    var at: []const u8 = ctx.cwd;
    // The repository: the cwd or the nearest folder above with a .git.
    while (true) {
        const git = std.fmt.bufPrint(&dir_buf, "{s}/.git/refs/heads", .{at}) catch return;
        var dir = std.Io.Dir.cwd().openDir(ctx.io, git, .{ .iterate = true }) catch {
            const up = std.fs.path.dirname(at) orelse return;
            if (up.len == at.len) return;
            at = up;
            continue;
        };
        defer dir.close(ctx.io);
        var walker = dir.walk(m.gpa) catch return;
        defer walker.deinit();
        while (walker.next(ctx.io) catch null) |e| {
            if (e.kind != .file or !std.mem.startsWith(u8, e.path, word)) continue;
            m.add(e.path, "", .branch);
        }
        return;
    }
}

test "completing commands, git, files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var cmds: Commands.Commands = .init(gpa);
    defer cmds.deinit();
    for ([_][]const u8{ "git", "grep", "gzip", "ls" }) |c| cmds.add(c);
    std.mem.sort([]const u8, cmds.sorted.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    const dir = "/tmp/nanoterm-test-complete";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir ++ "/src/ui");
    try std.Io.Dir.cwd().createDirPath(io, dir ++ "/.git/refs/heads/feature");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/stack.zig", .data = "" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/.git/refs/heads/main", .data = "" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/.git/refs/heads/feature/menu", .data = "" });
    const ctx: Context = .{ .io = io, .cwd = dir, .home = dir, .commands = &cmds };

    var m: Menu = .init(gpa);
    defer m.deinit();
    compute(&m, "g", 1, ctx);
    try std.testing.expectEqual(@as(usize, 3), m.items.items.len);
    try std.testing.expectEqualStrings("g", m.commonPrefix());
    compute(&m, "git sta", 7, ctx);
    try std.testing.expectEqual(@as(usize, 2), m.items.items.len); // stash, status
    try std.testing.expectEqualStrings("sta", m.commonPrefix());
    compute(&m, "cat s", 5, ctx);
    try std.testing.expectEqual(@as(usize, 2), m.items.items.len);
    try std.testing.expectEqualStrings("src/", m.items.items[0].word); // folders first
    try std.testing.expectEqual(@as(usize, 4), m.start);
    compute(&m, "ls src/", 7, ctx);
    try std.testing.expectEqualStrings("src/ui/", m.items.items[0].word);
    compute(&m, "git switch fe", 13, ctx);
    try std.testing.expectEqualStrings("feature/menu", m.items.items[0].word);
    try std.testing.expectEqual(Kind.branch, m.items.items[0].kind);
    var cmd_name = "review".*;
    var desc = "review code".*;
    var hint = "".*;
    const slash = [_]agent_config.Command{.{ .name = &cmd_name, .description = &desc, .hint = &hint }};
    var actx = ctx;
    actx.slash = &slash;
    compute(&m, "/re", 3, actx);
    try std.testing.expectEqualStrings("/review", m.items.items[0].word);
}
