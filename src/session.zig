//! A session: what one pane holds — its shell, its agent, the timeline of
//! blocks and agent turns, what is typed — and what the user does with it.
//! `Shared` is what the sessions of a window have in common.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const blocks = @import("blocks.zig");
const shell_mod = @import("shell.zig");
const agent_mod = @import("agent.zig");
const proc = @import("proc.zig");
const split = @import("split.zig");
const classify = @import("classify.zig");
const complete = @import("complete.zig");
const attach = @import("attach.zig");
pub const Commands = @import("commands.zig").Commands;
pub const History = @import("history.zig").History;
pub const Jev = @import("jev.zig").Jev;
pub const Catalog = @import("catalog.zig").Catalog;
const visual_host = @import("visual_host.zig");
const ssh = @import("ssh.zig");
const helpers = @import("session_agent.zig");
pub const Log = @import("session_log.zig").Log;

pub const Appearance = enum { system, dark, light };

pub const Mode = enum { terminal, agent };

pub const Entry = union(enum) {
    block: *blocks.Block,
    turn: *agent_mod.Turn,
};

/// What the sessions of a window share: the environment, the home
/// directory, where the shell integration lives, the window to redraw.
pub const Shared = struct {
    gpa: std.mem.Allocator,
    /// This frame's find (⌘F) in the focused pane, for the blocks.
    find: @import("find.zig").State = .{},
    io: std.Io,
    arena: std.mem.Allocator,
    env: *std.process.Environ.Map,
    /// The environment as "KEY=value", for agents and their commands.
    env_list: []const []const u8 = &.{},
    home: []const u8,
    zdotdir: []const u8,
    window: ?*nanoui.Window = null,
    next_session: u64 = 1,
    /// The programs on PATH, for the classifier and completion.
    commands: Commands,
    /// The commands run, in every pane.
    history: History,
    jev: Jev,
    /// graff's models, read when the picker first opens.
    catalog: Catalog,
    /// graff's saved model ("provider\nmodel"), shown until a session says.
    graff_model: []const u8 = "",
    /// Where agents' visuals come in (show_visual), and this program, which
    /// is their MCP server too.
    visuals: ?*visual_host.Host = null,
    exe: []const u8 = "",
    /// The conversations had, this run and before (the palette's history).
    log: Log,
    /// The pictures answers show.
    pictures: @import("pictures.zig").Cache,
    /// Light or dark, or as the system is (⌘P), and the file it is kept in.
    appearance: Appearance = .system,
    appearance_path: []const u8 = "",
    /// The hosts of ~/.ssh/config, for the palette.
    ssh_hosts: []const []const u8 = &.{},
    /// Settings (⌘,): the default agent, text size, Codegraff account.
    prefs: @import("settings.zig").Prefs,

    /// Call `wire` once the value is at its final address.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, env: *std.process.Environ.Map) !Shared {
        const home = env.get("HOME") orelse "/";
        try augmentPath(arena, io, env, home);
        var list: std.ArrayList([]const u8) = .empty;
        var it = env.iterator();
        while (it.next()) |e| try list.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }));
        var s: Shared = .{
            .gpa = gpa,
            .io = io,
            .arena = arena,
            .env = env,
            .env_list = list.items,
            .home = home,
            .zdotdir = try std.fs.path.join(arena, &.{ home, "Library", "Application Support", "nanoterm", "zsh" }),
            .commands = .init(gpa),
            .history = .{ .gpa = gpa },
            .jev = .init(gpa, io, env),
            .catalog = .{ .gpa = gpa },
            .log = .{ .gpa = gpa },
            .pictures = .{ .gpa = gpa, .io = io, .home = home, .fetch = true },
            .prefs = .init(gpa, io, arena, home, env),
        };
        s.log.load(io, try std.fs.path.join(arena, &.{ home, "Library", "Application Support", "nanoterm", "sessions.jsonl" }));
        s.appearance_path = try std.fs.path.join(arena, &.{ home, "Library", "Application Support", "nanoterm", "appearance" });
        if (std.Io.Dir.cwd().readFileAlloc(io, s.appearance_path, arena, .limited(64))) |data| {
            s.appearance = std.meta.stringToEnum(Appearance, std.mem.trim(u8, data, " \n")) orelse .system;
        } else |_| {}
        s.commands.scan(io, env.get("PATH") orelse "");
        s.history.load(io, try std.fs.path.join(arena, &.{ home, ".zsh_history" }), try std.fs.path.join(arena, &.{ home, "Library", "Application Support", "nanoterm", "history" }));
        s.graff_model = graffModel(arena, io, home);
        s.exe = std.process.executablePathAlloc(io, arena) catch "";
        s.ssh_hosts = ssh.hosts(arena, io, home);
        s.visuals = visual_host.Host.create(gpa, io, env.get("TMPDIR") orelse "/tmp") catch null;
        return s;
    }

    /// Points callbacks at the Shared where it now lives.
    pub fn wire(s: *Shared) void {
        @import("view_markdown.zig").pictures = &s.pictures;
        s.jev.changed = .{ .ctx = s, .func = redrawCtx };
        s.catalog.changed = .{ .ctx = s, .func = redrawCtx };
        s.pictures.changed = .{ .ctx = s, .func = redrawCtx };
        s.prefs.account.changed = .{ .ctx = s, .func = redrawCtx };
        s.prefs.graff.changed = .{ .ctx = s, .func = redrawCtx };
        s.prefs.account.key_changed = .{ .ctx = &s.jev, .func = @import("jev.zig").Jev.setKey };
        s.prefs.account.load();
    }

    pub fn deinit(s: *Shared) void {
        if (s.visuals) |h| h.destroy();
        s.log.deinit();
        s.pictures.deinit();
        if (@import("view_markdown.zig").pictures == &s.pictures) @import("view_markdown.zig").pictures = null;
        s.commands.deinit();
        s.history.deinit();
        s.jev.deinit();
        s.catalog.deinit();
        s.prefs.deinit();
    }

    fn redrawCtx(ctx: *anyopaque) void {
        const s: *Shared = @ptrCast(@alignCast(ctx));
        s.redraw();
    }

    pub fn redraw(s: *Shared) void {
        if (s.window) |w| w.redraw();
    }

    /// Chooses light, dark or the system's, and keeps the choice.
    pub fn setAppearance(s: *Shared, a: Appearance) void {
        s.appearance = a;
        if (s.appearance_path.len == 0) return;
        if (std.fs.path.dirname(s.appearance_path)) |dir| std.Io.Dir.cwd().createDirPath(s.io, dir) catch {};
        std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = s.appearance_path, .data = @tagName(a) }) catch {};
        s.redraw();
    }

    /// Starts reading graff's catalog, for the model picker.
    pub fn loadCatalog(s: *Shared) void {
        const graff = proc.which(s.arena, s.io, s.env.get("PATH") orelse "", "graff") orelse {
            s.catalog.state = .failed;
            return;
        };
        s.catalog.load(s.arena, graff, proc.cStrings(s.arena, s.env_list) catch return);
    }
};

/// graff's saved model, read (never written): "model" of "provider\nmodel".
fn graffModel(arena: std.mem.Allocator, io: std.Io, home: []const u8) []const u8 {
    const path = std.fs.path.join(arena, &.{ home, ".simple-harness-model" }) catch return "";
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4096)) catch return "";
    var lines = std.mem.tokenizeAny(u8, data, "\r\n");
    _ = lines.next();
    return std.mem.trim(u8, lines.next() orelse "", " ");
}

pub const Session = struct {
    id: u64,
    shared: *Shared,
    gpa: std.mem.Allocator,
    io: std.Io,
    arena: std.mem.Allocator,
    home: []const u8,
    shell: shell_mod.Shell,
    agent: ?*agent_mod.Agent = null,
    which: agent_mod.Which = .graff,
    /// Every block made, owned here; the timeline and turns point to them.
    all_blocks: std.ArrayList(*blocks.Block) = .empty,
    timeline: std.ArrayList(Entry) = .empty,
    input: ui.TextBuffer = .{},
    /// Pictures that go with the next prompt.
    attachments: attach.Tray,
    /// The mode chosen with ⌘I or the mode pill; null detects it.
    lock: ?Mode = null,
    /// What the classifier made of the input, and for which text.
    guess: classify.Guess = .{ .kind = .shell, .sure = true },
    guessed: u64 = 0,
    /// How far back ↑ went in the history.
    history_pos: ?usize = null,
    /// The completion menu of the input.
    menu: complete.Menu,
    /// graff's model for its next start (`--model`).
    model_choice: ?[]u8 = null,
    selected: ?u64 = null,
    next_id: u64 = 1,
    shell_exited: bool = false,
    branch: [128]u8 = undefined,
    branch_len: usize = 0,
    branch_for: std.ArrayList(u8) = .empty,
    cols: u16 = 100,
    /// Commands given with --run, run in turn as the shell gets ready,
    /// then the prompt given with --ask.
    queue: std.ArrayList([]const u8) = .empty,
    queued_ask: ?[]const u8 = null,
    /// Agents switched away from: their turns stay in the timeline.
    retired: std.ArrayList(*agent_mod.Agent) = .empty,
    /// A turn to bring into view (the palette jumped to it).
    reveal: ?*const agent_mod.Turn = null,
    /// What was just run or asked (its index in the timeline): followed
    /// until its top reaches the top of the view, then kept there to be
    /// read from its start, until the reader scrolls. `pin_jump` brings it
    /// into view once.
    pin: ?usize = null,
    pin_jump: u2 = 0,
    /// The id of its input in the last frame, for the focus.
    input_id: u64 = 0,
    /// The caret in its input in the last frame, for Tab.
    caret: usize = 0,
    /// Where its pane was laid out in the last frame.
    rect: split.Rect = .{},
    rows: u16 = 40,
    /// The timeline's top in the last frame, and the block whose header
    /// scrolled above it while its output still shows (pinned there).
    timeline_top: ?f32 = null,
    sticky: ?*blocks.Block = null,
    sticky_y: f32 = 0,
    /// How tall its input, floating over the timeline, was in the last frame;
    /// and which of Vim's modes it was in.
    composer_h: f32 = 124,
    vim: enum { insert, normal, visual } = .insert,

    /// A session whose shell starts in `cwd`.
    pub fn create(shared: *Shared, cwd_: []const u8) !*Session {
        const gpa = shared.gpa;
        const a = try gpa.create(Session);
        a.* = .{
            .id = shared.next_session,
            .shared = shared,
            .gpa = gpa,
            .io = shared.io,
            .arena = shared.arena,
            .home = shared.home,
            .shell = .init(gpa, .{ .ctx = a, .changed = changed, .exited = shellExited }),
            .menu = .init(gpa),
            .attachments = .{ .gpa = gpa },
            .which = shared.prefs.agent,
        };
        shared.next_session += 1;
        a.startShell(cwd_) catch |err| {
            std.log.err("nanoterm: the shell did not start: {s}", .{@errorName(err)});
            a.shell_exited = true;
        };
        return a;
    }

    pub fn destroy(a: *Session) void {
        a.deinit();
        a.gpa.destroy(a);
    }

    fn deinit(a: *Session) void {
        if (a.agent) |ag| ag.destroy();
        for (a.retired.items) |ag| ag.destroy();
        a.retired.deinit(a.gpa);
        a.shell.deinit();
        for (a.all_blocks.items) |b| b.destroy(a.gpa);
        a.all_blocks.deinit(a.gpa);
        a.timeline.deinit(a.gpa);
        a.menu.deinit();
        a.attachments.deinit();
        if (a.model_choice) |m| a.gpa.free(m);
        a.branch_for.deinit(a.gpa);
        a.queue.deinit(a.gpa);
    }

    fn startShell(a: *Session, start_dir: []const u8) !void {
        // A copy: the shell adds its own variables.
        var env = try a.shared.env.clone(a.arena);
        try a.shell.start(a.arena, a.io, a.shared.zdotdir, a.home, &env, start_dir, .{ .rows = a.rows, .cols = a.cols });
    }

    /// What the tab shows: the command running, else the directory's name.
    pub fn title(a: *Session) []const u8 {
        if (a.shell.current) |b| return b.command;
        const dir = a.cwd();
        if (std.mem.eql(u8, dir, a.home)) return "~";
        return std.fs.path.basename(dir);
    }

    /// Fits the shell's terminal to `cols` × `rows`.
    pub fn fit(a: *Session, cols: u16, rows: u16) void {
        if (cols == a.cols and rows == a.rows) return;
        a.cols = cols;
        a.rows = rows;
        a.shell.resize(rows, cols);
    }

    pub fn changed(ctx: *anyopaque) void {
        const a: *Session = @ptrCast(@alignCast(ctx));
        a.pump();
        a.shared.redraw();
    }

    /// Runs the next queued command once the shell waits at its prompt.
    fn pump(a: *Session) void {
        if (a.shell.phase != .ready or a.shell.busy()) return;
        if (a.queue.items.len > 0) {
            const cmd = a.queue.orderedRemove(0);
            a.run(cmd);
        } else if (a.queued_ask) |q| {
            a.queued_ask = null;
            a.lock = .agent;
            a.ask(q);
        }
    }

    fn shellExited(ctx: *anyopaque, _: i32) void {
        const a: *Session = @ptrCast(@alignCast(ctx));
        a.shell_exited = true;
        changed(a);
    }

    pub fn cwd(a: *Session) []const u8 {
        return if (a.shell.cwd.items.len > 0) a.shell.cwd.items else a.home;
    }

    /// The git branch of the working directory, read when it changes.
    pub fn gitBranch(a: *Session) []const u8 {
        const dir = a.cwd();
        if (!std.mem.eql(u8, dir, a.branch_for.items)) {
            a.branch_for.clearRetainingCapacity();
            a.branch_for.appendSlice(a.gpa, dir) catch {};
            a.branch_len = blocks.gitBranch(a.io, &a.branch, dir).len;
        }
        return a.branch[0..a.branch_len];
    }

    pub fn newBlock(a: *Session, source: blocks.Source, command: []const u8, dir: []const u8) ?*blocks.Block {
        var buf: [128]u8 = undefined;
        const branch = blocks.gitBranch(a.io, &buf, dir);
        const b = blocks.Block.create(a.gpa, a.next_id, source, command, dir, branch) catch return null;
        a.next_id += 1;
        a.all_blocks.append(a.gpa, b) catch {
            b.destroy(a.gpa);
            return null;
        };
        return b;
    }

    /// Where an agent's commands become blocks of this session (for tests
    /// that make the agent themselves).
    pub const agentBlockFn = agentBlock;

    fn agentBlock(ctx: *anyopaque, command: []const u8, dir: []const u8) ?*blocks.Block {
        const a: *Session = @ptrCast(@alignCast(ctx));
        return a.newBlock(.agent, command, dir);
    }

    /// Where what is typed goes: the program running, else the mode chosen,
    /// else what the classifier (or Jev) made of it.
    pub fn mode(a: *const Session) Mode {
        if (!a.shared.prefs.agents) return .terminal;
        // On an SSH host, commands unless clearly a request (its programs
        // are not on this machine's PATH for the classifier to know).
        if (a.shell.remoteReady()) {
            if (a.lock) |m| return m;
            if (a.attachments.items.items.len > 0) return .agent;
            const t = std.mem.trim(u8, a.input.text(), " ");
            if (t.len > 0 and t[t.len - 1] == '?') return .agent;
            return if (a.guess.kind == .agent and a.guess.sure) .agent else .terminal;
        }
        if (a.shell.busy()) return .terminal;
        if (a.lock) |m| return m;
        // Pictures are for the agent.
        if (a.attachments.items.items.len > 0) return .agent;
        // A reply to the agent stays with it; Jev reads the text alone.
        if (!(a.followUp() and a.guess.kind == .agent)) if (a.shared.jev.answer(a.input.text())) |k| return if (k == .agent) .agent else .terminal;
        return if (a.guess.kind == .agent) .agent else .terminal;
    }

    /// Whether Jev decided the mode of what is typed.
    pub fn decidedByJev(a: *const Session) bool {
        return a.lock == null and !a.shell.busy() and !(a.followUp() and a.guess.kind == .agent) and a.shared.jev.answer(a.input.text()) != null;
    }

    /// The agent answered last: a reply is likelier a follow-up.
    pub fn followUp(a: *const Session) bool {
        const items = a.timeline.items;
        return items.len > 0 and items[items.len - 1] == .turn;
    }

    /// Classifies the input when it changed; asks Jev when the rules are
    /// not sure, and starts the agent early when it is wanted.
    pub fn observe(a: *Session) void {
        const text = a.input.text();
        const h = std.hash.Wyhash.hash(0, text);
        if (h == a.guessed) return;
        a.guessed = h;
        a.guess = classify.guess(text, &a.shared.commands, a.followUp());
        if (a.lock != null or a.shell.busy()) return;
        if (a.shared.prefs.agents and !a.guess.sure and std.mem.indexOfScalar(u8, std.mem.trim(u8, text, " "), ' ') != null) a.shared.jev.ask(text);
        // Ready before Return is pressed.
        if (a.mode() == .agent and a.guess.sure and a.agent == null) _ = a.ensureAgent();
    }

    /// Runs what was typed: a command, input for the command running, or a
    /// prompt for the agent.
    pub fn submit(a: *Session) void {
        if (@import("session_program.zig").reading(a)) return @import("session_program.zig").line(a);
        const text = std.mem.trim(u8, a.input.text(), " \t");
        if (text.len == 0) return;
        const m = a.mode();
        const copy = a.gpa.dupe(u8, text) catch return;
        defer a.gpa.free(copy);
        if (m == .terminal and !a.shell.busy()) a.shared.history.record(copy);
        a.history_pos = null;
        a.input.clear();
        a.menu.close();
        switch (m) {
            .agent => @import("assist.zig").ask(a, copy),
            .terminal => a.run(copy),
        }
    }

    pub fn run(a: *Session, command: []const u8) void {
        // On a set-up SSH host: a block of its own, run there.
        if (a.shell.remoteReady()) {
            const r = a.shell.remote.?;
            const where = std.fmt.allocPrint(a.arena, "{s}:{s}", .{ r.host, r.cwd.items }) catch return;
            const b = a.newBlock(.shell, command, where) orelse return;
            a.timeline.append(a.gpa, .{ .block = b }) catch return;
            a.pinLast();
            a.shell.submitRemote(b);
            return;
        }
        // The shell is still starting (a new tab): run it at the first
        // prompt, or its marks would end the block before it starts.
        if (a.shell.phase == .starting) {
            a.queue.append(a.gpa, a.arena.dupe(u8, command) catch return) catch {};
            return;
        }
        if (a.shell.busy()) {
            // A command runs: what is typed is its input.
            a.shell.input(command);
            a.shell.input("\n");
            return;
        }
        if (std.mem.eql(u8, command, "clear")) return a.clear();
        const b = a.newBlock(.shell, command, a.cwd()) orelse return;
        a.timeline.append(a.gpa, .{ .block = b }) catch return;
        a.pinLast();
        a.selected = null;
        // `ssh host`: its connection shared, for the agent to use once you
        // have signed in; the session's commands become blocks once set up.
        if (ssh.parse(command)) |t| if (t.interactive) {
            var buf: [128]u8 = undefined;
            const dir = ssh.ensureDir(&buf);
            const sent = ssh.shared(a.arena, command, dir) catch command;
            a.shell.submitAs(b, sent);
            a.shell.startRemote(b, command, ssh.host(t.dest));
            return;
        };
        a.shell.submit(b);
    }

    pub fn ask(a: *Session, text: []const u8) void {
        a.askAs(null, text);
    }

    /// A prompt whose turn shows `title` (a short line) instead of `text`.
    pub fn askAs(a: *Session, heading: ?[]const u8, text: []const u8) void {
        const ag = a.ensureAgent() orelse return;
        // On an SSH host: the agent works there, and is told so.
        a.syncRemote(ag);
        if (ag.remote) |r| {
            const said = std.fmt.allocPrint(a.arena,
                \\[nanoterm: this pane is in an SSH session on `{s}` (opened with `{s}`), in `{s}`. Commands you run through the terminal tool, and files you read or write through the client, are on that host. To run something there yourself: `ssh -o ControlPath={s}/%C -o BatchMode=yes {s} -- <command>` (already signed in).]
                \\
                \\{s}
            , .{ r.host, r.session, r.cwd, r.dir, std.mem.trimStart(u8, r.session[3..], " "), text }) catch text;
            ag.promptWith(heading orelse text, said, a.attachments.take()) catch return;
        } else {
            const said = helpers.followShell(a, ag, text);
            ag.promptWith(if (said.ptr == text.ptr) heading else heading orelse text, said, a.attachments.take()) catch return;
        }
        a.shared.prefs.track("agent_prompt", .{ .agent = @tagName(a.which) });
        if (ag.current()) |t| {
            a.timeline.append(a.gpa, .{ .turn = t }) catch return;
            a.pinLast();
        }
    }

    pub const finished = helpers.finished;
    pub const offerVisuals = helpers.offerVisuals;
    const syncRemote = helpers.syncRemote;

    fn pinLast(a: *Session) void {
        a.pin = a.timeline.items.len - 1;
        a.pin_jump = 2;
    }

    /// Clears the timeline (the blocks stay owned until the app ends).
    pub fn clear(a: *Session) void {
        a.timeline.clearRetainingCapacity();
        a.pin = null;
        a.selected = null;
    }

    pub fn interrupt(a: *Session) void {
        if (a.agent) |ag| if (ag.status == .working) return ag.cancel();
        if (a.shell.busy()) a.shell.interrupt();
    }

    /// ⌘I: the other mode, chosen until changed back (Esc on an empty
    /// input returns to detecting it).
    pub fn toggleMode(a: *Session) void {
        a.lock = if (a.mode() == .terminal) .agent else .terminal;
        a.menu.close();
    }

    /// Switches agents: the next prompt starts a new conversation.
    pub fn choose(a: *Session, which: agent_mod.Which) void {
        if (a.which == which) return;
        a.which = which;
        if (a.agent) |ag| {
            if (ag.status == .working) ag.cancel();
            // Its turns stay in the timeline; it is kept until the app ends.
            a.retired.append(a.gpa, ag) catch {};
            a.agent = null;
        }
    }

    /// ↑ and ↓ through the commands run, newest first.
    pub fn historyStep(a: *Session, back: bool) void {
        const h = &a.shared.history;
        if (h.len() == 0) return;
        if (back) {
            const next = if (a.history_pos) |p| @min(p + 1, h.len() - 1) else 0;
            a.history_pos = next;
            a.input.set(h.back(next).?);
        } else if (a.history_pos) |p| {
            if (p == 0) {
                a.history_pos = null;
                a.input.clear();
            } else {
                a.history_pos = p - 1;
                a.input.set(h.back(p - 1).?);
            }
        }
    }

    pub fn ensureAgent(a: *Session) ?*agent_mod.Agent {
        if (a.agent) |ag| return ag;
        const ag = agent_mod.Agent.create(a.gpa, a.io, .{ .ctx = a, .changed = changed, .newBlock = agentBlock, .finished = finished }, a.which, a.cwd()) catch return null;
        ag.env = a.shared.env_list;
        a.agent = ag;
        a.offerVisuals(ag);
        const argv = @import("agent_launch.zig").argv(a.arena, a.io, a.shared.env, a.which, a.model_choice) catch {
            ag.status = .failed;
            ag.error_text = std.fmt.allocPrint(a.gpa, "{s} is not installed", .{a.which.label()}) catch null;
            return ag;
        };
        ag.start(argv, proc.cStrings(a.arena, a.shared.env_list) catch return ag) catch {};
        return ag;
    }
};

/// Apps opened from the Finder get a bare PATH: add where tools live.
fn augmentPath(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, home: []const u8) !void {
    var parts: std.ArrayList(u8) = .empty;
    try parts.appendSlice(arena, env.get("PATH") orelse "/usr/bin:/bin:/usr/sbin:/sbin");
    const extra = [_][]const u8{ "/opt/homebrew/bin", "/usr/local/bin", "/.local/bin", "/.bun/bin", "/.cargo/bin" };
    for (extra) |dir| {
        const full = if (dir[1] == '.') try std.fmt.allocPrint(arena, "{s}{s}", .{ home, dir }) else dir;
        if (std.mem.indexOf(u8, parts.items, full) == null) {
            try parts.append(arena, ':');
            try parts.appendSlice(arena, full);
        }
    }
    // nvm's newest node, for agents' adapters written in JavaScript.
    const nvm = try std.fmt.allocPrint(arena, "{s}/.nvm/versions/node", .{home});
    if (std.Io.Dir.cwd().openDir(io, nvm, .{ .iterate = true })) |dir_| {
        var dir = dir_;
        defer dir.close(io);
        var it = dir.iterate();
        var newest: ?[]const u8 = null;
        while (it.next(io) catch null) |e| {
            if (e.kind == .directory and (newest == null or std.mem.order(u8, e.name, newest.?) == .gt)) newest = try arena.dupe(u8, e.name);
        }
        if (newest) |v| {
            try parts.append(arena, ':');
            try parts.appendSlice(arena, try std.fmt.allocPrint(arena, "{s}/{s}/bin", .{ nvm, v }));
        }
    } else |_| {}
    try env.put("PATH", parts.items);
}
