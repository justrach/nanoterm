//! Files the system asks nanoterm to open (Finder's Open With, `open -a
//! nanoterm FILE`, `nt FILE`, a file named at launch): each in a tab in its
//! folder, shown as `cat` shows it (Markdown drawn as Markdown, pictures
//! as pictures); a folder, a tab in it. A first tab no one has used yet
//! gives way to them.
const std = @import("std");
const Workspace = @import("workspace.zig").Workspace;

pub fn open(ctx: *anyopaque, paths: []const []const u8) void {
    const w: *Workspace = @ptrCast(@alignCast(ctx));
    const io = w.shared.io;
    const arena = w.shared.arena;
    const fresh = if (w.tabs.items.len == 1) untouched(w) else false;
    var opened: usize = 0;
    for (paths) |p| {
        const is_dir = if (std.Io.Dir.cwd().openDir(io, p, .{})) |d_| blk: {
            var d = d_;
            d.close(io);
            break :blk true;
        } else |_| false;
        const dir = if (is_dir) p else std.fs.path.dirname(p) orelse continue;
        const s = w.newTab(dir) catch continue;
        if (!is_dir) {
            const cmd = catCommand(arena, std.fs.path.basename(p)) catch continue;
            s.queue.append(w.shared.gpa, cmd) catch {};
        }
        opened += 1;
    }
    if (fresh and opened > 0) w.closeTab(0);
    if (opened > 0) w.selectTab(w.tabs.items.len - 1);
    w.shared.redraw();
}

/// The first tab as it started: nothing run, nothing asked.
fn untouched(w: *Workspace) bool {
    const s = w.tabs.items[0].session();
    return s.timeline.items.len == 0 and s.queue.items.len == 0 and s.agent == null;
}

/// `cat 'NAME'`, quoted for the shell.
pub fn catCommand(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "cat '");
    for (name) |ch| {
        if (ch == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, ch);
    }
    try out.append(a, '\'');
    return out.items;
}

test "a file is shown with cat, quoted for the shell" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("cat 'REPORT.md'", try catCommand(a, "REPORT.md"));
    try std.testing.expectEqualStrings("cat 'it'\\''s here.md'", try catCommand(a, "it's here.md"));
}
