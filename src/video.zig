//! A 30-second video of nanoterm, drawn by nanoui: the scenes
//! (video_scenes.zig) run in a Tester, offscreen, 30 frames a second, and
//! each frame's pixels go to standard output for ffmpeg. nanoterm's own view
//! draws its window: the script types into its input and presses keys
//! through the Tester (Esc, k into the output, search, select, copy). The
//! commands' output and the agent's answer are written in
//! (video_data.zig): nothing runs, no agent is asked, no window shows.
//!
//!     zig build video && zig-out/bin/nanoterm-video | ffmpeg -f rawvideo \
//!       -pix_fmt bgra -s 1920x1080 -r 30 -i - -pix_fmt yuv420p out.mp4
//!     zig-out/bin/nanoterm-video --still=12:/tmp/frame.png   # one frame
//!     zig-out/bin/nanoterm-video --cues    # when keys and cuts come
//!     zig-out/bin/nanoterm-video --dark
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const session_mod = @import("session.zig");
const ws_mod = @import("workspace.zig");
const agent_mod = @import("agent.zig");
const data = @import("video_data.zig");
const scenes = @import("video_scenes.zig");
const Director = scenes.Director;

const fps = 30;
const scale = 1.5;
const T = scenes.at.term;

const Act = union(enum) {
    /// Text typed into the input over `dur`, as shell or agent.
    type: struct { text: []const u8, dur: f32, agent: bool = false },
    /// Return: the block (or the turn) appears, written in.
    run_test,
    ask,
    run_cat,
    /// Keys, through the view: characters, or a key combination.
    chars: []const u8,
    key: u21,
};

const Step = struct { at: f32, act: Act };

const steps = [_]Step{
    .{ .at = T + 0.6, .act = .{ .type = .{ .text = data.test_cmd, .dur = 0.9 } } },
    .{ .at = T + 1.7, .act = .run_test },
    .{ .at = T + 2.6, .act = .{ .type = .{ .text = data.question, .dur = 1.2, .agent = true } } },
    .{ .at = T + 4.0, .act = .ask },
    .{ .at = T + 6.9, .act = .{ .type = .{ .text = data.cat_cmd, .dur = 0.6 } } },
    .{ .at = T + 7.6, .act = .run_cat },
    .{ .at = T + 8.3, .act = .{ .key = ui.Shortcut.escape } },
    .{ .at = T + 8.8, .act = .{ .chars = "k" } },
    .{ .at = T + 9.4, .act = .{ .chars = "gg" } },
    .{ .at = T + 9.9, .act = .{ .chars = "/" } },
    .{ .at = T + 10.05, .act = .{ .chars = "V" } },
    .{ .at = T + 10.2, .act = .{ .chars = "i" } },
    .{ .at = T + 10.35, .act = .{ .chars = "m" } },
    .{ .at = T + 10.6, .act = .{ .key = ui.Shortcut.enter } },
    .{ .at = T + 11.2, .act = .{ .chars = "V" } },
    .{ .at = T + 11.5, .act = .{ .chars = "j" } },
    .{ .at = T + 11.8, .act = .{ .chars = "j" } },
    .{ .at = T + 12.1, .act = .{ .chars = "y" } },
    .{ .at = T + 12.6, .act = .{ .chars = "q" } },
};

const captions = [_]scenes.Caption{
    .{ T + 8.2, T + 8.75, "Esc", "normal mode" },
    .{ T + 8.75, T + 9.35, "k", "into the output" },
    .{ T + 9.35, T + 9.85, "gg", "to the top" },
    .{ T + 9.85, T + 11.1, "/Vim ⏎", "search" },
    .{ T + 11.1, T + 12.5, "V j j y", "copy three lines" },
    .{ T + 12.5, T + 13.0, "q", "back to the input" },
};

/// When the agent's answer streams in, and when it is done.
const answer_from = T + 4.3;
const answer_to = T + 6.3;

/// The times sounds go with (`--cues`): keys and Returns, the answer, cuts.
fn cues(io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const o = &w.interface;
    for (steps) |s| switch (s.act) {
        .type => {},
        else => try o.print("click {d:.3}\n", .{s.at}),
    };
    try o.print("answer {d:.3}\n", .{answer_to});
    const at = scenes.at;
    for ([_]f32{ at.term, at.bench, at.fixes, at.end }) |cut| try o.print("cut {d:.3}\n", .{cut});
    try o.flush();
}

const Script = struct {
    gpa: std.mem.Allocator,
    s: *session_mod.Session,
    next: usize = 0,
    typing: ?struct { text: []const u8, from: f32, dur: f32, agent: bool } = null,
    turn: ?*agent_mod.Turn = null,

    /// Moves time on to `now`; the input for this frame, if any, goes in `t`.
    fn step(sc: *Script, t: *ui.Tester, now: f32) void {
        const s = sc.s;
        if (sc.typing) |ty| {
            const n: usize = @intFromFloat(std.math.clamp((now - ty.from) / ty.dur, 0, 1) * @as(f32, @floatFromInt(ty.text.len)));
            if (!std.mem.eql(u8, s.input.text(), ty.text[0..n])) s.input.set(ty.text[0..n]);
            // As the classifier would say, without asking anyone.
            s.guess = .{ .kind = if (ty.agent) .agent else .shell, .sure = true };
            s.guessed = std.hash.Wyhash.hash(0, s.input.text());
        }
        if (sc.turn) |turn| if (!turn.done) {
            const p = std.math.clamp((now - answer_from) / (answer_to - answer_from), 0, 1);
            const n: usize = @intFromFloat(p * @as(f32, @floatFromInt(data.answer.len)));
            const text = &turn.items.items[0].text;
            text.clearRetainingCapacity();
            text.appendSlice(sc.gpa, data.answer[0..n]) catch {};
            if (p >= 1) {
                turn.done = true;
                turn.ended = turn.started + 6.1;
            }
        };
        while (sc.next < steps.len and now >= steps[sc.next].at) : (sc.next += 1) switch (steps[sc.next].act) {
            .type => |ty| sc.typing = .{ .text = ty.text, .from = now, .dur = ty.dur, .agent = ty.agent },
            .run_test => sc.block(data.test_cmd, data.test_out, 1, 2.84),
            .run_cat => sc.block(data.cat_cmd, data.readme, 0, 0.01),
            .ask => sc.ask(),
            .chars => |ch| t.ctx.input.chars = ch,
            .key => |k| {
                t.ctx.shortcut_taken = false;
                t.ctx.input.shortcut = .{ .key = k };
            },
        };
    }

    fn deinit(sc: *Script) void {
        const turn = sc.turn orelse return;
        for (turn.items.items) |*it| if (it.* == .text) it.text.deinit(sc.gpa);
        turn.items.deinit(sc.gpa);
        sc.gpa.free(turn.prompt);
        sc.gpa.destroy(turn);
    }

    /// After the frame: this frame's input is spent.
    fn spent(_: *Script, t: *ui.Tester) void {
        t.ctx.input.chars = "";
        t.ctx.input.shortcut = null;
    }

    fn done(sc: *Script) void {
        sc.typing = null;
        sc.s.input.clear();
        settle(sc.s);
    }

    /// The empty input after an answer reads as a follow-up, which starts the
    /// agent early: it is decided here, so no agent ever starts.
    fn settle(s: *session_mod.Session) void {
        s.guess = .{ .kind = .shell, .sure = true };
        s.guessed = std.hash.Wyhash.hash(0, "");
    }

    fn block(sc: *Script, cmd: []const u8, out: []const u8, code: i32, secs: f64) void {
        sc.done();
        const s = sc.s;
        const b = s.newBlock(.shell, cmd, s.cwd()) orelse return;
        b.output.feed(out) catch {};
        b.started = 1000;
        b.ended = 1000 + secs;
        b.exit_code = code;
        b.state = .done;
        s.timeline.append(sc.gpa, .{ .block = b }) catch {};
    }

    fn ask(sc: *Script) void {
        sc.done();
        const turn = sc.gpa.create(agent_mod.Turn) catch return;
        turn.* = .{ .prompt = sc.gpa.dupe(u8, data.question) catch return, .agent = .graff, .started = 2000, .sent = true };
        turn.items.append(sc.gpa, .{ .text = .empty }) catch {};
        sc.turn = turn;
        sc.s.timeline.append(sc.gpa, .{ .turn = turn }) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var stills: std.ArrayList(struct { frame: usize, path: []const u8 }) = .empty;
    defer stills.deinit(gpa);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var dark = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--cues")) return cues(io);
        if (std.mem.eql(u8, arg, "--dark")) {
            dark = true;
            continue;
        }
        const prefix = "--still=";
        if (!std.mem.startsWith(u8, arg, prefix)) return error.UnknownArgument;
        const v = arg[prefix.len..];
        const colon = std.mem.indexOfScalar(u8, v, ':') orelse return error.BadStill;
        const secs = try std.fmt.parseFloat(f32, v[0..colon]);
        try stills.append(gpa, .{ .frame = @intFromFloat(@round(secs * fps)), .path = v[colon + 1 ..] });
    }

    // A home of its own: no settings, history or agents of the user's.
    const arena = init.arena.allocator();
    const home = "/tmp/nanoterm-video-home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    shared.prefs.keys = .vim;
    shared.appearance = if (dark) .dark else .light;
    theme.apply(if (dark) .dark else .light);
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    const s = try w.newTab(home);
    Script.settle(s);

    var d: Director = .{ .w = &w, .dark = dark, .captions = &captions };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&d, Director.view), .{ .width = scenes.width, .height = scenes.height, .scale = scale, .theme = theme.ui() });
    defer t.deinit();
    t.dt = 1.0 / @as(f32, fps);
    t.time = 0;

    var last: usize = @intFromFloat(scenes.at.done * fps);
    if (stills.items.len > 0) {
        last = 0;
        for (stills.items) |st| last = @max(last, st.frame + 1);
    }
    var script: Script = .{ .gpa = gpa, .s = s };
    defer script.deinit();
    const out = std.Io.File.stdout();
    for (0..last) |i| {
        const now = @as(f32, @floatFromInt(i)) / fps;
        d.now = now;
        script.step(&t, now);
        t.frame();
        script.spent(&t);
        if (stills.items.len > 0) {
            for (stills.items) |st| if (st.frame == i) try t.screenshot(st.path);
            continue;
        }
        const pixels = try t.render(gpa);
        defer pixels.deinit(gpa);
        try out.writeStreamingAll(io, pixels.bytes);
    }
}
