//! What makes the input smart, in the manner of Warp: a failed command
//! offers to have the agent fix or explain it, a selected block goes with
//! a prompt as its context, Tab completes and → takes the suggestion, and
//! the model picker's choices reach whichever agent the pane runs.
const std = @import("std");
const blocks = @import("blocks.zig");
const complete = @import("complete.zig");
const agent_mod = @import("agent.zig");
const Session = @import("session.zig").Session;

/// Output lines a block gives as context.
const context_lines = 80;

pub const Ask = enum { fix, explain };

/// The block's command, where it ran, how it ended, and its last lines.
fn describe(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: *Session, b: *blocks.Block) !void {
    const dir = if (std.mem.startsWith(u8, b.cwd, s.home)) b.cwd[s.home.len..] else b.cwd;
    try out.print(gpa, "$ {s}\n(in {s}{s}", .{ b.command, if (dir.len < b.cwd.len) "~" else "", dir });
    if (b.exit_code) |code| try out.print(gpa, ", exit code {d}", .{code});
    try out.appendSlice(gpa, ")\n");
    const lines = b.output.lines.items;
    const count = b.output.lineCount();
    const first = count -| context_lines;
    if (first > 0) try out.print(gpa, "[… {d} earlier lines]\n", .{first + b.output.dropped});
    for (lines[first..count]) |*l| {
        try out.appendSlice(gpa, l.text.items);
        try out.append(gpa, '\n');
    }
}

/// Asks the agent to fix or explain block `b` (a failed command's buttons).
pub fn askAbout(s: *Session, b: *blocks.Block, what: Ask) void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(s.gpa);
    const lead = switch (what) {
        .fix => "This command failed in my terminal. Find out why and fix it, then run it again to check.\n\n```\n",
        .explain => "Explain what happened when I ran this command in my terminal, and what I could do next. Do not change anything.\n\n```\n",
    };
    text.appendSlice(s.gpa, lead) catch return;
    describe(&text, s.gpa, s, b) catch return;
    text.appendSlice(s.gpa, "```") catch return;
    var title_buf: [200]u8 = undefined;
    const short = b.command[0..@min(b.command.len, 120)];
    const title = std.fmt.bufPrint(&title_buf, "{s} `{s}`", .{ if (what == .fix) "Fix" else "Explain", short }) catch "Fix";
    s.askAs(title, text.items);
}

/// The block selected, which a prompt takes as context.
pub fn attached(s: *Session) ?*blocks.Block {
    const id = s.selected orelse return null;
    for (s.all_blocks.items) |b| if (b.id == id) return b;
    return null;
}

/// Sends `text` to the agent, with the selected block as its context.
pub fn ask(s: *Session, text: []const u8) void {
    const b = attached(s) orelse return s.ask(text);
    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(s.gpa);
    full.print(s.gpa, "{s}\n\nContext, a command I ran:\n```\n", .{text}) catch return;
    describe(&full, s.gpa, s, b) catch return;
    full.appendSlice(s.gpa, "```") catch return;
    s.selected = null;
    s.askAs(text, full.items);
}

// The model picker.

/// What the picker shows as the pane's model.
pub fn modelLabel(s: *Session) []const u8 {
    if (s.agent) |ag| if (ag.config.find("model")) |o| return o.currentName();
    if (s.model_choice) |m| return m;
    if (s.which == .graff and s.shared.graff_model.len > 0) return s.shared.graff_model;
    return "default model";
}

/// Chooses `value` as the model: an agent's own model option when it has
/// one; for graff, its `/model` command in a conversation, else `--model`
/// for its next start.
pub fn chooseModel(s: *Session, value: []const u8) void {
    if (s.agent) |ag| if (ag.config.find("model")) |o| return ag.setOption(o.id, value);
    if (s.model_choice) |m| s.gpa.free(m);
    s.model_choice = s.gpa.dupe(u8, value) catch null;
    if (s.agent) |ag| {
        if (ag.turns.items.len > 0 and ag.session != null and ag.config.hasCommand("model")) {
            var buf: [256]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "/model {s}", .{value}) catch return;
            return s.askAs(cmd, cmd);
        }
        // Nothing said yet: start it again on the new model.
        if (ag.status == .working) ag.cancel();
        s.retired.append(s.gpa, ag) catch ag.destroy();
        s.agent = null;
        _ = s.ensureAgent();
    }
}

/// Opens the agent so the picker can show what it offers.
pub fn prepareModels(s: *Session) void {
    _ = s.ensureAgent();
    if (s.which == .graff) s.shared.loadCatalog();
}

// Completion.

fn context(s: *Session) complete.Context {
    return .{
        .io = s.io,
        .cwd = s.cwd(),
        .home = s.home,
        .commands = &s.shared.commands,
        .slash = if (s.mode() == .agent) if (s.agent) |ag| ag.config.commands.items else &.{} else null,
    };
}

/// The suggestion drawn after what is typed: a command from the history,
/// or a slash command's argument hint.
pub fn suggestion(s: *Session) []const u8 {
    const text = s.input.text();
    if (text.len == 0 or s.menu.open) return "";
    if (s.mode() == .agent) {
        const ag = s.agent orelse return "";
        if (text[0] != '/' or std.mem.indexOfScalar(u8, text, ' ') != null) return "";
        for (ag.config.commands.items) |c| if (std.mem.eql(u8, c.name, text[1..]) and c.hint.len > 0) {
            return if (std.mem.startsWith(u8, c.hint, text)) c.hint[@min(c.hint.len, text.len)..] else "";
        };
        return "";
    }
    if (s.shell.busy()) return "";
    return s.shared.history.suggestIf(text, Here{ .io = s.io, .cwd = s.cwd(), .home = s.home }, reachable);
}

/// Where a command would run, to tell whether it still makes sense there.
pub const Here = struct { io: std.Io, cwd: []const u8, home: []const u8 };

/// Whether `cmd` can run from `here`: a cd (or pushd) only if its directory
/// is there, as fish checks before suggesting one; anything else, yes.
pub fn reachable(here: Here, cmd: []const u8) bool {
    const arg = for ([_][]const u8{ "cd ", "pushd " }) |verb| {
        if (std.mem.startsWith(u8, cmd, verb)) break std.mem.trim(u8, cmd[verb.len..], " \t");
    } else return true;
    // What the shell would expand (variables, globs, quotes, -), it judges.
    if (arg.len == 0 or std.mem.eql(u8, arg, "-") or std.mem.indexOfAny(u8, arg, "$`*?[\"' ;&|") != null) return true;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (std.mem.startsWith(u8, arg, "~/") or std.mem.eql(u8, arg, "~"))
        std.fmt.bufPrint(&buf, "{s}{s}", .{ here.home, arg[1..] }) catch return true
    else if (arg[0] == '~')
        return true // another user's home
    else if (arg[0] == '/')
        arg
    else
        std.fmt.bufPrint(&buf, "{s}/{s}", .{ here.cwd, arg }) catch return true;
    var dir = std.Io.Dir.cwd().openDir(here.io, path, .{}) catch return false;
    dir.close(here.io);
    return true;
}

/// Tab: takes the suggestion, else completes the word at the caret.
pub fn tab(s: *Session, caret: usize) void {
    if (s.menu.open) return accept(s);
    const sug = suggestion(s);
    if (sug.len > 0 and caret == s.input.len) {
        var buf: [1024]u8 = undefined;
        s.input.set(std.fmt.bufPrint(&buf, "{s}{s}", .{ s.input.text(), sug }) catch return);
        return;
    }
    complete.compute(&s.menu, s.input.text(), caret, context(s));
    const items = s.menu.items.items;
    if (items.len == 0) return;
    if (items.len == 1) return accept(s);
    // Several: what they share goes in, and the menu opens.
    const common = s.menu.commonPrefix();
    if (common.len > s.menu.end - s.menu.start) replaceWord(s, common, false);
    s.menu.open = true;
}

/// Opens the slash commands as "/" is typed in agent mode, and keeps an
/// open menu up to date as the word changes.
pub fn typed(s: *Session, caret: usize) void {
    s.menu.dismissed = false;
    const text = s.input.text();
    const slash = slashing(s);
    if (!s.menu.open and !slash) return;
    if (text.len == 0 or (text[text.len - 1] == ' ' and !slash)) return s.menu.close();
    const selected = s.menu.selected;
    complete.compute(&s.menu, text, caret, context(s));
    s.menu.open = s.menu.items.items.len > 0;
    s.menu.selected = @min(selected, s.menu.items.items.len -| 1);
}

fn slashing(s: *Session) bool {
    const text = s.input.text();
    return s.mode() == .agent and text.len > 0 and text[0] == '/' and std.mem.indexOfScalar(u8, text, ' ') == null;
}

/// Each frame: opens the slash commands once the agent has told them,
/// if "/" was typed before it had.
pub fn refresh(s: *Session) void {
    if (s.menu.open or s.menu.dismissed or !slashing(s)) return;
    const ag = s.agent orelse return;
    if (ag.config.commands.items.len == 0) return;
    typed(s, s.caret);
}

/// Takes the menu's selected candidate.
pub fn accept(s: *Session) void {
    const items = s.menu.items.items;
    if (items.len == 0) return s.menu.close();
    const it = items[@min(s.menu.selected, items.len - 1)];
    // A folder keeps completing; anything else is a whole word.
    replaceWord(s, it.word, it.kind != .folder);
    s.menu.close();
}

fn replaceWord(s: *Session, word: []const u8, space: bool) void {
    const text = s.input.text();
    var buf: [1024]u8 = undefined;
    const out = std.fmt.bufPrint(&buf, "{s}{s}{s}{s}", .{ text[0..s.menu.start], word, if (space) " " else "", text[@min(s.menu.end, text.len)..] }) catch return;
    s.menu.end = s.menu.start + word.len;
    s.input.set(out);
    s.input.want_caret = s.menu.start + word.len + @intFromBool(space);
}

test "a cd is suggested only where its directory is" {
    const io = std.testing.io;
    const root = "/tmp/nanoterm-test-reach";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/advark/advark-website");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    var h: @import("history.zig").History = .{ .gpa = std.testing.allocator };
    defer h.deinit();
    h.add("cd advark-website");
    h.add("cd advark/");
    // From the root, advark/ is there; from inside it, it isn't, and the
    // next one back that is (advark-website) is suggested instead.
    const top: Here = .{ .io = io, .cwd = root, .home = root };
    const inside: Here = .{ .io = io, .cwd = root ++ "/advark", .home = root };
    try std.testing.expectEqualStrings("/", h.suggestIf("cd advark", top, reachable));
    try std.testing.expectEqualStrings("-website", h.suggestIf("cd advark", inside, reachable));
    // ~, absolute paths, and what the shell expands.
    try std.testing.expect(reachable(inside, "cd ~/advark"));
    try std.testing.expect(!reachable(inside, "cd ~/nowhere"));
    try std.testing.expect(reachable(inside, "cd " ++ root));
    try std.testing.expect(reachable(inside, "cd $HOME/x"));
    try std.testing.expect(reachable(inside, "cd -"));
    try std.testing.expect(reachable(inside, "git status"));
}
