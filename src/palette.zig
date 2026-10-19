//! The command palette (⌘P), as Warp's: every action by name with its
//! keys, the commands run lately, and what is typed sent to the agent —
//! filtered by a fuzzy match as you type.
const std = @import("std");
const Workspace = @import("workspace.zig").Workspace;
const Session = @import("session.zig").Session;
const assist = @import("assist.zig");
/// A key combination as this platform writes it.
const K = @import("nanoui").ui.keys.label;
const binds = @import("binds.zig");

pub const Action = struct {
    label: []const u8,
    /// Other words it is found by ("light mode").
    also: []const u8 = "",
    keys: []const u8 = "",
    icon: []const u8,
    run: *const fn (w: *Workspace) void,
};

fn S(comptime f: fn (*Workspace) void) *const fn (*Workspace) void {
    return f;
}

pub const actions = [_]Action{
    .{ .label = "Settings", .also = "preferences sign in codegraff account agents install update", .keys = binds.label("Cmd+,"), .icon = "gearshape", .run = S(struct {
        fn f(w: *Workspace) void {
            w.closeOverlay();
            w.openSettings();
        }
    }.f) },
    .{ .label = "Choose agent and model", .keys = binds.label("Cmd+Shift+M"), .icon = "cpu", .run = S(struct {
        fn f(w: *Workspace) void {
            w.openModels();
        }
    }.f) },
    .{ .label = "Toggle agent mode", .keys = binds.label("Cmd+I"), .icon = "sparkles", .run = S(struct {
        fn f(w: *Workspace) void {
            w.focused().toggleMode();
        }
    }.f) },
    .{ .label = "Detect mode automatically", .icon = "wand.and.stars", .run = S(struct {
        fn f(w: *Workspace) void {
            w.focused().lock = null;
        }
    }.f) },
    .{ .label = "Split right", .keys = binds.label("Cmd+D"), .icon = "rectangle.split.2x1", .run = S(struct {
        fn f(w: *Workspace) void {
            w.splitFocused(.horizontal);
        }
    }.f) },
    .{ .label = "Split down", .keys = binds.label("Cmd+Shift+D"), .icon = "rectangle.split.1x2", .run = S(struct {
        fn f(w: *Workspace) void {
            w.splitFocused(.vertical);
        }
    }.f) },
    .{ .label = "New tab", .keys = binds.label("Cmd+T"), .icon = "plus.square", .run = S(struct {
        fn f(w: *Workspace) void {
            _ = w.newTab(w.focused().cwd()) catch {};
        }
    }.f) },
    .{ .label = "Close pane", .keys = binds.label("Cmd+W"), .icon = "xmark.square", .run = S(struct {
        fn f(w: *Workspace) void {
            w.closeFocused();
        }
    }.f) },
    .{ .label = "Zoom pane", .keys = binds.label("Cmd+Shift+Enter"), .icon = "arrow.up.left.and.arrow.down.right", .run = S(struct {
        fn f(w: *Workspace) void {
            w.toggleZoom();
        }
    }.f) },
    .{ .label = "Equalize splits", .keys = binds.label("Cmd+Ctrl+="), .icon = "equal.square", .run = S(struct {
        fn f(w: *Workspace) void {
            w.equalize();
        }
    }.f) },
    .{ .label = "Next pane", .keys = binds.label("Cmd+]"), .icon = "arrow.right.square", .run = S(struct {
        fn f(w: *Workspace) void {
            w.focusNext(1);
        }
    }.f) },
    .{ .label = "Clear blocks", .keys = binds.label("Cmd+K"), .icon = "clear", .run = S(struct {
        fn f(w: *Workspace) void {
            w.focused().clear();
        }
    }.f) },
    .{ .label = "Stop what runs", .keys = K("⌃C"), .icon = "stop.circle", .run = S(struct {
        fn f(w: *Workspace) void {
            w.focused().interrupt();
        }
    }.f) },
    .{ .label = "Ask the agent to fix the last failed command", .icon = "wrench.and.screwdriver", .run = S(struct {
        fn f(w: *Workspace) void {
            const s = w.focused();
            var i = s.all_blocks.items.len;
            while (i > 0) {
                i -= 1;
                const b = s.all_blocks.items[i];
                if (b.source == .shell and b.failed()) return assist.askAbout(s, b, .fix);
            }
        }
    }.f) },
    .{ .label = "Appearance: Light", .also = "light mode theme day colors", .icon = "sun.max", .run = S(struct {
        fn f(w: *Workspace) void {
            w.shared.setAppearance(.light);
        }
    }.f) },
    .{ .label = "Appearance: Dark", .also = "dark mode theme night colors", .icon = "moon", .run = S(struct {
        fn f(w: *Workspace) void {
            w.shared.setAppearance(.dark);
        }
    }.f) },
    .{ .label = "Appearance: Match system", .also = "auto mode theme system colors", .icon = "circle.lefthalf.filled", .run = S(struct {
        fn f(w: *Workspace) void {
            w.shared.setAppearance(.system);
        }
    }.f) },
    .{ .label = "Use graff", .icon = "sparkles", .run = S(struct {
        fn f(w: *Workspace) void {
            w.focused().choose(.graff);
        }
    }.f) },
    .{ .label = "Use Claude Code", .icon = "sparkles", .run = S(struct {
        fn f(w: *Workspace) void {
            w.focused().choose(.claude);
        }
    }.f) },
};

/// How well `query` matches `text`: its characters in order, scored for
/// starts of words and runs; null when they are not all there.
pub fn score(text: []const u8, query: []const u8) ?i32 {
    if (query.len == 0) return 0;
    var s: i32 = 0;
    var qi: usize = 0;
    var prev_match = false;
    for (text, 0..) |ch, i| {
        if (qi == query.len) break;
        if (std.ascii.toLower(ch) == std.ascii.toLower(query[qi])) {
            const word_start = i == 0 or !std.ascii.isAlphanumeric(text[i - 1]);
            s += 1 + @as(i32, if (word_start) 8 else 0) + @as(i32, if (prev_match) 4 else 0);
            qi += 1;
            prev_match = true;
        } else prev_match = false;
    }
    if (qi < query.len) return null;
    // Shorter texts win ties.
    return s * 4 - @as(i32, @intCast(@min(text.len, 200) / 8));
}

/// What the palette searches: everything, or one kind (Tab cycles).
pub const Scope = enum {
    all,
    sessions,
    history,
    actions,
    commands,
    ssh,

    pub fn label(sc: Scope) []const u8 {
        return switch (sc) {
            .all => "All",
            .sessions => "Sessions",
            .history => "History",
            .actions => "Actions",
            .commands => "Commands",
            .ssh => "SSH",
        };
    }
};

/// One row of the palette.
pub const Entry = union(enum) {
    action: *const Action,
    run: []const u8,
    ask: []const u8,
    /// An open pane.
    pane: *Session,
    /// A conversation in the session history (index into the log).
    past: usize,
    /// An SSH host to connect to (from ~/.ssh/config, or as typed).
    ssh_host: []const u8,
};

pub const Section = struct { title: []const u8, start: usize };

pub const Results = struct {
    entries: std.ArrayList(Entry) = .empty,
    sections: std.ArrayList(Section) = .empty,
};

const Scored = struct { e: Entry, s: i32 };

fn best(a: std.mem.Allocator, list: *std.ArrayList(Scored)) void {
    _ = a;
    std.mem.sort(Scored, list.items, {}, struct {
        fn gt(_: void, x: Scored, y: Scored) bool {
            return x.s > y.s;
        }
    }.gt);
}

fn section(r: *Results, a: std.mem.Allocator, title: []const u8, list: []const Scored, limit: usize) void {
    if (list.len == 0) return;
    r.sections.append(a, .{ .title = title, .start = r.entries.items.len }) catch return;
    for (list[0..@min(list.len, limit)]) |x| r.entries.append(a, x.e) catch return;
}

/// What a pane is called: its directory, its agent, what it did last.
pub fn paneText(a: std.mem.Allocator, s: *Session) []const u8 {
    return std.fmt.allocPrint(a, "{s} {s} {s}", .{ s.cwd(), s.which.label(), lastThing(s) }) catch "";
}

/// The last prompt or command of a pane.
pub fn lastThing(s: *Session) []const u8 {
    var i = s.timeline.items.len;
    while (i > 0) {
        i -= 1;
        switch (s.timeline.items[i]) {
            .turn => |t| return t.title orelse t.prompt,
            .block => |b| if (b.command.len > 0) return b.command,
        }
    }
    return "";
}

/// The rows matching `query` in `scope`, in sections, best first.
pub fn search(r: *Results, a: std.mem.Allocator, w: *Workspace, query: []const u8, scope: Scope) void {
    r.entries.clearRetainingCapacity();
    r.sections.clearRetainingCapacity();
    const all = scope == .all;
    // A sentence (three words or more) goes to the agent first; fewer,
    // after what matches.
    var words = std.mem.tokenizeScalar(u8, query, ' ');
    var n_words: usize = 0;
    while (words.next()) |_| n_words += 1;
    const sentence = n_words >= 3;
    if (all and sentence) {
        r.sections.append(a, .{ .title = "Agent", .start = 0 }) catch {};
        r.entries.append(a, .{ .ask = query }) catch {};
    }
    if (all or scope == .sessions) {
        var list: std.ArrayList(Scored) = .empty;
        for (w.tabs.items) |tab| {
            var leaves: std.ArrayList(*@import("workspace.zig").Node) = .empty;
            tab.tree.leaves(&leaves, a) catch continue;
            for (leaves.items) |n| {
                const s = n.kind.leaf;
                if (score(paneText(a, s), query)) |sc| list.append(a, .{ .e = .{ .pane = s }, .s = sc }) catch {};
            }
        }
        if (query.len > 0) best(a, &list);
        section(r, a, "Open sessions", list.items, if (all) 4 else 50);
    }
    if (all or scope == .history) {
        var list: std.ArrayList(Scored) = .empty;
        const log = w.shared.log.entries.items;
        var i = log.len;
        while (i > 0 and list.items.len < 400) {
            i -= 1;
            const e = log[i];
            const sc = score(e.prompt, query) orelse (if (query.len > 2) (if (score(e.reply, query)) |x| @divTrunc(x, 2) else null) else null) orelse continue;
            // Newer first among equals.
            list.append(a, .{ .e = .{ .past = i }, .s = sc - @as(i32, @intCast((log.len - i) / 20)) }) catch {};
        }
        if (query.len > 0) best(a, &list);
        section(r, a, "History", list.items, if (all) 5 else 100);
    }
    if (all or scope == .actions) {
        var list: std.ArrayList(Scored) = .empty;
        for (&actions) |*act| {
            const by_label = score(act.label, query);
            const by_also = if (act.also.len > 0) score(act.also, query) else null;
            const sc = if (by_label) |x| (if (by_also) |y| @max(x, y) else x) else by_also orelse continue;
            list.append(a, .{ .e = .{ .action = act }, .s = sc }) catch {};
        }
        if (query.len > 0) best(a, &list);
        section(r, a, "Actions", list.items, if (all) 5 else 50);
    }
    if (all or scope == .commands) {
        var list: std.ArrayList(Scored) = .empty;
        const h = &w.shared.history;
        var i: usize = 0;
        while (i < @min(h.len(), 300)) : (i += 1) {
            const cmd = h.back(i).?;
            if (score(cmd, query)) |sc| list.append(a, .{ .e = .{ .run = cmd }, .s = sc - @as(i32, @intCast(i / 30)) }) catch {};
        }
        if (query.len > 0) best(a, &list);
        section(r, a, "Recent commands", list.items, if (all) 5 else 60);
    }
    if (all or scope == .ssh) {
        var list: std.ArrayList(Scored) = .empty;
        // What is typed, when it looks like a destination.
        const typed = std.mem.trim(u8, if (std.mem.startsWith(u8, query, "ssh ")) query[4..] else query, " ");
        if (typed.len > 0 and std.mem.indexOfScalar(u8, typed, ' ') == null and (std.mem.indexOfScalar(u8, typed, '@') != null or std.mem.startsWith(u8, query, "ssh ")))
            list.append(a, .{ .e = .{ .ssh_host = typed }, .s = 1000 }) catch {};
        const q = if (std.mem.startsWith(u8, query, "ssh ")) typed else query;
        for (w.shared.ssh_hosts) |h| if (score(h, q) orelse (if (q.len == 0) @as(?i32, 0) else null)) |sc| list.append(a, .{ .e = .{ .ssh_host = h }, .s = sc }) catch {};
        if (query.len > 0) best(a, &list);
        section(r, a, "SSH hosts", list.items, if (all) 4 else 60);
    }
    if (all and !sentence and query.len > 0) {
        r.sections.append(a, .{ .title = "Agent", .start = r.entries.items.len }) catch {};
        r.entries.append(a, .{ .ask = query }) catch {};
    }
}

test "fuzzy scores" {
    try std.testing.expect(score("Split right", "spr") != null);
    try std.testing.expect(score("Split right", "xyz") == null);
    // Starts of words beat letters inside them.
    try std.testing.expect(score("Split right", "sr").? > score("Close pane", "se").?);
    try std.testing.expect(score("git status", "gs").? > score("logs", "gs").?);
}
