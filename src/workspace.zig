//! A window's tabs, each a tree of split panes holding sessions, and what
//! Ghostty's keys do to them: split right (⌘D) and down (⌘⇧D), move the
//! focus (⌘] ⌘[ and ⌘⌥ arrows), resize (⌘⌃ arrows), equalize (⌘⌃=),
//! zoom (⌘⇧↩), close (⌘W); new tab (⌘T), next and previous (⌘⇧] ⌘⇧[),
//! tab n (⌘1…⌘9).
const std = @import("std");
const nanoui = @import("nanoui");
const split = @import("split.zig");
const session_mod = @import("session.zig");
const Session = session_mod.Session;
const Shared = session_mod.Shared;

pub const Tree = split.Tree(*Session);

/// A panel over the panes: the command palette, the model picker.
pub const Overlay = enum { none, palette, models, settings };
pub const Node = Tree.Node;

pub const Tab = struct {
    tree: Tree,
    /// The focused pane: always a leaf.
    focused: *Node,
    /// The focused pane fills the tab (⌘⇧↩).
    zoomed: bool = false,

    pub fn session(t: *const Tab) *Session {
        return t.focused.kind.leaf;
    }
};

const resize_step = 0.05;

pub const Workspace = struct {
    shared: *Shared,
    nanoapp: *nanoui.App,
    /// Updates from the releases (none in tests), and the version put off
    /// with "Later".
    updater: ?*nanoui.Updater = null,
    update_later: [32]u8 = undefined,
    update_later_len: usize = 0,
    tabs: std.ArrayList(*Tab) = .empty,
    active: usize = 0,
    /// Where the panes of the active tab were laid out in the last frame.
    placed: std.ArrayList(Tree.Placed) = .empty,
    overlay: Overlay = .none,
    /// What the palette searches (Tab cycles).
    scope: @import("palette.zig").Scope = .all,
    /// The overlay's search, and its row chosen with ↑↓.
    query: nanoui.ui.TextBuffer = .{},
    pick: usize = 0,
    /// Every text's size times this (⌘= ⌘- ⌘0).
    zoom: f32 = 1,
    /// Find (⌘F): what is searched for, and the match shown.
    find: nanoui.ui.TextBuffer = .{},
    finding: bool = false,
    find_index: usize = 0,
    /// The current match changed: scroll to it.
    find_scroll: bool = false,

    pub fn deinit(w: *Workspace) void {
        for (w.tabs.items) |t| w.freeTab(t);
        w.tabs.deinit(w.shared.gpa);
        w.placed.deinit(w.shared.gpa);
    }

    pub fn zoomBy(w: *Workspace, by: f32) void {
        w.zoom = std.math.clamp(w.zoom + by, 0.6, 2.5);
    }

    /// ⌘F: the find bar, or back to it with what was searched.
    pub fn openFind(w: *Workspace) void {
        w.finding = true;
        w.overlay = .none;
    }

    pub fn closeFind(w: *Workspace) void {
        w.finding = false;
        w.find_index = 0;
    }

    pub fn openPalette(w: *Workspace) void {
        w.overlay = if (w.overlay == .palette) .none else .palette;
        w.query.clear();
        w.pick = 0;
        w.scope = .all;
    }

    /// The model picker; it starts the pane's agent to learn its models.
    pub fn openModels(w: *Workspace) void {
        w.overlay = if (w.overlay == .models) .none else .models;
        if (w.overlay == .models) w.shared.prefs.refresh(w.shared.env);
        w.query.clear();
        w.pick = 0;
        if (w.overlay == .models) @import("assist.zig").prepareModels(w.focused());
    }

    /// Settings (⌘,): the agents are looked for again as it opens.
    pub fn openSettings(w: *Workspace) void {
        w.overlay = if (w.overlay == .settings) .none else .settings;
        if (w.overlay == .settings) w.shared.prefs.refresh(w.shared.env);
    }

    pub fn closeOverlay(w: *Workspace) void {
        w.overlay = .none;
        w.query.clear();
    }

    fn freeTab(w: *Workspace, t: *Tab) void {
        var leaves: std.ArrayList(*Node) = .empty;
        defer leaves.deinit(w.shared.gpa);
        t.tree.leaves(&leaves, w.shared.gpa) catch {};
        for (leaves.items) |n| n.kind.leaf.destroy();
        t.tree.deinit();
        w.shared.gpa.destroy(t);
    }

    pub fn tab(w: *Workspace) *Tab {
        return w.tabs.items[w.active];
    }

    pub fn focused(w: *Workspace) *Session {
        return w.tab().session();
    }

    /// A new tab with one session in `cwd`, made active.
    pub fn newTab(w: *Workspace, cwd: []const u8) !*Session {
        const s = try Session.create(w.shared, cwd);
        errdefer s.destroy();
        const t = try w.shared.gpa.create(Tab);
        errdefer w.shared.gpa.destroy(t);
        t.* = .{ .tree = try Tree.init(w.shared.gpa, s), .focused = undefined };
        t.focused = t.tree.root;
        try w.tabs.insert(w.shared.gpa, if (w.tabs.items.len == 0) 0 else w.active + 1, t);
        w.active = if (w.tabs.items.len == 1) 0 else w.active + 1;
        return s;
    }

    /// Splits the focused pane; the new session starts where it is, as
    /// Ghostty's new splits inherit the working directory.
    pub fn splitFocused(w: *Workspace, axis: split.Axis) void {
        const t = w.tab();
        const s = Session.create(w.shared, w.focused().cwd()) catch return;
        const leaf = t.tree.split(t.focused, axis, s) catch {
            s.destroy();
            return;
        };
        t.zoomed = false;
        t.focused = leaf;
    }

    /// Closes the focused pane, asking first if a command still runs.
    /// The last pane closes its tab; the last tab, the window.
    pub fn closeFocused(w: *Workspace) void {
        const t = w.tab();
        const s = t.session();
        if (s.shell.busy()) {
            const answer = nanoui.dialog.message(.{
                .title = "Close this pane?",
                .detail = "A command is still running in it; closing stops it.",
                .kind = .warning,
                .buttons = &.{ "Close", "Cancel" },
            });
            if (answer.button != 0) return;
        }
        if (t.tree.remove(t.focused)) |next| {
            s.destroy();
            t.focused = next;
            t.zoomed = false;
            return;
        }
        // The tab's only pane.
        _ = w.tabs.orderedRemove(w.active);
        w.freeTab(t);
        if (w.tabs.items.len == 0) {
            if (w.shared.window) |win| {
                w.shared.window = null;
                win.close();
            }
            return;
        }
        w.active = @min(w.active, w.tabs.items.len - 1);
    }

    /// The open session with id `id`, in any tab.
    pub fn findSession(w: *Workspace, id: u64) ?*Session {
        var buf: [64]*Node = undefined;
        for (w.tabs.items) |t| for (leavesOf(t, &buf)) |n| if (n.kind.leaf.id == id) return n.kind.leaf;
        return null;
    }

    /// Shows session `s`: its tab, its pane focused. False if it is gone.
    pub fn focusSession(w: *Workspace, s: *Session) bool {
        var buf: [64]*Node = undefined;
        for (w.tabs.items, 0..) |t, i| for (leavesOf(t, &buf)) |n| if (n.kind.leaf == s) {
            w.active = i;
            t.focused = n;
            return true;
        };
        return false;
    }

    fn leavesOf(t: *Tab, buf: []*Node) []*Node {
        var list: std.ArrayList(*Node) = .initBuffer(buf);
        collect(t.tree.root, &list);
        return list.items;
    }

    fn collect(n: *Node, out: *std.ArrayList(*Node)) void {
        switch (n.kind) {
            .leaf => if (out.items.len < out.capacity) out.appendAssumeCapacity(n),
            .split => |sp| {
                collect(sp.first, out);
                collect(sp.second, out);
            },
        }
    }

    pub fn focus(w: *Workspace, n: *Node) void {
        w.tab().focused = n;
    }

    /// The pane holding session `s` in the active tab, if any.
    pub fn nodeOf(w: *Workspace, s: *Session) ?*Node {
        for (w.placed.items) |p| if (p.node.kind.leaf == s) return p.node;
        return null;
    }

    /// The next (or previous) pane in order (⌘] ⌘[).
    pub fn focusNext(w: *Workspace, delta: isize) void {
        const t = w.tab();
        var leaves: std.ArrayList(*Node) = .empty;
        defer leaves.deinit(w.shared.gpa);
        t.tree.leaves(&leaves, w.shared.gpa) catch return;
        const n: isize = @intCast(leaves.items.len);
        for (leaves.items, 0..) |l, i| if (l == t.focused) {
            const next = @mod(@as(isize, @intCast(i)) + delta, n);
            t.focused = leaves.items[@intCast(next)];
            t.zoomed = false;
            return;
        };
    }

    /// The pane in `dir` from the focused one (⌘⌥ arrows).
    pub fn focusDirection(w: *Workspace, dir: split.Direction) void {
        const t = w.tab();
        const from = for (w.placed.items) |p| {
            if (p.node == t.focused) break p.rect;
        } else return;
        if (Tree.neighbor(w.placed.items, from, dir)) |n| t.focused = n;
    }

    pub fn resizeFocused(w: *Workspace, dir: split.Direction) void {
        _ = Tree.resize(w.tab().focused, dir, resize_step);
    }

    pub fn equalize(w: *Workspace) void {
        Tree.equalize(w.tab().tree.root);
    }

    pub fn toggleZoom(w: *Workspace) void {
        const t = w.tab();
        if (t.tree.root.kind == .leaf) return;
        t.zoomed = !t.zoomed;
    }

    pub fn selectTab(w: *Workspace, i: usize) void {
        if (i < w.tabs.items.len) w.active = i;
    }

    pub fn nextTab(w: *Workspace, delta: isize) void {
        const n: isize = @intCast(w.tabs.items.len);
        w.active = @intCast(@mod(@as(isize, @intCast(w.active)) + delta, n));
    }

    /// Closes tab `i` pane by pane, asking where a command runs.
    pub fn closeTab(w: *Workspace, i: usize) void {
        if (i >= w.tabs.items.len) return;
        w.active = i;
        const t = w.tab();
        while (true) {
            const leaves = Tree.count(t.tree.root);
            const tabs_before = w.tabs.items.len;
            w.closeFocused();
            // The tab is gone, or a close was canceled.
            if (w.tabs.items.len < tabs_before or Tree.count(t.tree.root) == leaves) return;
        }
    }
};
