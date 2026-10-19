//! Codegraff's Jev, asked what the input is when the rules are not sure:
//! one "choice" question (shell or agent) about a redacted copy of what is
//! typed, as graff asks Jev for a turn's effort. It is asked while typing,
//! once typing pauses, one question at a time; answers are kept per text.
//! A failed call (no login, no credits, offline) turns it off for the
//! session, as graff's circuit does. The request goes through curl, which
//! reads its configuration (and so the key) from its input, never argv.
const std = @import("std");
const nanoui = @import("nanoui");
const proc = @import("proc.zig");
const classify = @import("classify.zig");

pub const default_endpoint = "https://gateway.codegraff.com/v1/systemone";
/// How long typing must pause before Jev is asked.
const pause_ms = 350;

pub const Jev = struct {
    gpa: std.mem.Allocator,
    /// The Codegraff login (`graff login`); null turns Jev off.
    key: ?[]u8 = null,
    endpoint: []const u8 = default_endpoint,
    /// A call failed: no more calls this session.
    down: bool = false,
    answers: std.StringHashMapUnmanaged(classify.Kind) = .empty,
    /// What to ask next, once typing pauses; and what is being asked.
    want: ?[]u8 = null,
    asking: ?[]u8 = null,
    /// Pause timers scheduled and not yet run.
    timers: u32 = 0,
    process: proc.Process = undefined,
    running: bool = false,
    reply: std.ArrayList(u8) = .empty,
    /// Called when an answer arrives.
    changed: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque) void } = null,
    /// Calls made, for the status line and tests.
    calls: usize = 0,

    /// Jev with the user's Codegraff login, unless NANOTERM_JEV=0.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) Jev {
        var j: Jev = .{ .gpa = gpa };
        const off = env.get("NANOTERM_JEV") orelse "";
        if (std.mem.eql(u8, off, "0") or std.ascii.eqlIgnoreCase(off, "off")) return j;
        const home = env.get("HOME") orelse return j;
        var path_buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/.simple-harness-codegraff.json", .{home}) catch return j;
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch return j;
        defer gpa.free(data);
        const parsed = std.json.parseFromSlice(struct { api_key: []const u8 = "" }, gpa, data, .{ .ignore_unknown_fields = true }) catch return j;
        defer parsed.deinit();
        if (parsed.value.api_key.len > 0) j.key = gpa.dupe(u8, parsed.value.api_key) catch null;
        return j;
    }

    pub fn deinit(j: *Jev) void {
        if (j.running) j.process.close();
        var it = j.answers.keyIterator();
        while (it.next()) |k| j.gpa.free(k.*);
        j.answers.deinit(j.gpa);
        if (j.want) |w| j.gpa.free(w);
        if (j.asking) |a| j.gpa.free(a);
        if (j.key) |k| j.gpa.free(k);
        j.reply.deinit(j.gpa);
    }

    /// The Codegraff key changed (signed in or out in Settings).
    pub fn setKey(ctx: *anyopaque, key: ?[]const u8) void {
        const j: *Jev = @ptrCast(@alignCast(ctx));
        if (j.key) |k| j.gpa.free(k);
        j.key = if (key) |k| j.gpa.dupe(u8, k) catch null else null;
        j.down = false;
    }

    pub fn available(j: *const Jev) bool {
        return j.key != null and !j.down;
    }

    /// Jev's answer for `text`, if it gave one.
    pub fn answer(j: *const Jev, text: []const u8) ?classify.Kind {
        return j.answers.get(std.mem.trim(u8, text, " \t"));
    }

    /// Asks about `text` once typing pauses (the latest text wins).
    pub fn ask(j: *Jev, text_in: []const u8) void {
        const text = std.mem.trim(u8, text_in, " \t");
        if (!j.available() or text.len == 0 or j.answers.contains(text)) return;
        if (j.want) |w| {
            if (std.mem.eql(u8, w, text)) return;
            j.gpa.free(w);
        }
        j.want = j.gpa.dupe(u8, text) catch null;
        j.timers += 1;
        nanoui.App.after(pause_ms, j, paused);
    }

    fn paused(ctx: ?*anyopaque) callconv(.c) void {
        const j: *Jev = @ptrCast(@alignCast(ctx));
        // Typing went on: the last timer asks.
        j.timers -= 1;
        if (j.timers == 0) j.start();
    }

    fn start(j: *Jev) void {
        if (j.running or !j.available()) return;
        const text = j.want orelse return;
        j.want = null;
        if (j.answers.contains(text)) return j.gpa.free(text);
        var buf: [280]u8 = undefined;
        const safe = classify.redact(&buf, text);
        if (safe.len == 0) return j.gpa.free(text);
        j.asking = text;
        j.request(safe) catch {
            j.gpa.free(text);
            j.asking = null;
            j.down = true;
        };
    }

    fn request(j: *Jev, safe: []const u8) !void {
        var arena_state: std.heap.ArenaAllocator = .init(j.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const body = try std.json.Stringify.valueAlloc(arena, .{
            .model = "jev-latest",
            .state = safe,
            .questions = .{ .q1 = .{
                .type = "choice",
                .instructions = "This was typed into a terminal that runs shell commands and also talks to a coding agent. Choose what it is.",
                .criteria = .{
                    .shell = "A shell command, to be run as typed",
                    .agent = "A request in natural language, for the coding agent",
                },
            } },
        }, .{});
        var config: std.ArrayList(u8) = .empty;
        try config.print(arena, "url = \"{s}\"\nheader = \"Authorization: Bearer {s}\"\nheader = \"Content-Type: application/json\"\nsilent\nfail\nmax-time = 6\ndata-binary = \"", .{ j.endpoint, j.key.? });
        for (body) |ch| switch (ch) {
            '\\' => try config.appendSlice(arena, "\\\\"),
            '"' => try config.appendSlice(arena, "\\\""),
            '\n' => try config.appendSlice(arena, "\\n"),
            else => try config.append(arena, ch),
        };
        try config.appendSlice(arena, "\"\n");
        j.reply.clearRetainingCapacity();
        try proc.spawnPipes(&j.process, try proc.cStrings(arena, &.{ "/usr/bin/curl", "-K", "-" }), try proc.cStrings(arena, &.{"PATH=/usr/bin:/bin"}), null, false, .{ .ctx = j, .output = onOutput, .exited = onExit });
        j.running = true;
        j.calls += 1;
        j.process.send(config.items);
        j.process.closeInput();
    }

    fn onOutput(ctx: *anyopaque, bytes: []const u8) void {
        const j: *Jev = @ptrCast(@alignCast(ctx));
        if (j.reply.items.len < 64 * 1024) j.reply.appendSlice(j.gpa, bytes) catch {};
    }

    fn onExit(ctx: *anyopaque, code: i32) void {
        const j: *Jev = @ptrCast(@alignCast(ctx));
        j.process.close();
        j.running = false;
        const text = j.asking orelse return;
        j.asking = null;
        const kind = if (code == 0) parse(j.gpa, j.reply.items) else null;
        if (kind) |k| {
            j.answers.put(j.gpa, text, k) catch j.gpa.free(text);
        } else {
            j.gpa.free(text);
            j.down = true;
        }
        if (j.changed) |c| c.func(c.ctx);
        // Typing went on while Jev answered: ask about the latest.
        if (j.want != null and j.timers == 0) j.start();
    }

    /// The choice in Jev's reply: {"answers":{"q1":{"choice":"agent",…}}}.
    pub fn parse(gpa: std.mem.Allocator, reply: []const u8) ?classify.Kind {
        const parsed = std.json.parseFromSlice(std.json.Value, gpa, reply, .{}) catch return null;
        defer parsed.deinit();
        const answers = if (parsed.value == .object) parsed.value.object.get("answers") orelse return null else return null;
        const q1 = if (answers == .object) answers.object.get("q1") orelse return null else return null;
        const choice = if (q1 == .object) q1.object.get("choice") orelse return null else return null;
        if (choice != .string) return null;
        return std.meta.stringToEnum(classify.Kind, choice.string);
    }
};

test "Jev's reply" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqual(classify.Kind.agent, Jev.parse(gpa, "{\"answers\":{\"q1\":{\"type\":\"choice\",\"choice\":\"agent\",\"confidence\":0.9}}}").?);
    try std.testing.expectEqual(classify.Kind.shell, Jev.parse(gpa, "{\"answers\":{\"q1\":{\"choice\":\"shell\"}}}").?);
    try std.testing.expect(Jev.parse(gpa, "{\"error\":\"no credits\"}") == null);
    try std.testing.expect(Jev.parse(gpa, "not json") == null);
}
