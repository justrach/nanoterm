//! A conversation with a coding agent over ACP: start the agent, open a
//! session in the terminal's directory, send prompts, and turn the
//! agent's updates into turns of messages, thoughts, tool calls, plans,
//! permission questions and the commands it runs (blocks).
const std = @import("std");
const acp = @import("acp.zig");
const blocks = @import("blocks.zig");
const host = @import("agent_host.zig");
const agent_config = @import("agent_config.zig");
const visual = @import("visual.zig");

pub const Which = enum {
    graff,
    claude,

    pub fn label(w: Which) []const u8 {
        return switch (w) {
            .graff => "graff",
            .claude => "Claude Code",
        };
    }
};

pub const Status = enum { off, starting, ready, working, failed };
pub const ToolStatus = enum { pending, in_progress, completed, failed };

pub const Tool = struct {
    id: []u8,
    title: std.ArrayList(u8) = .empty,
    kind: []u8,
    status: ToolStatus = .pending,
    /// What the tool showed: a diff's path, text output.
    detail: std.ArrayList(u8) = .empty,
    /// The command the tool runs, if it runs one in a terminal.
    block: ?*blocks.Block = null,
};

pub const PlanEntry = struct { text: []u8, status: []u8 };

pub const Option = struct { id: []u8, name: []u8, kind: []u8 };

pub const Permission = struct {
    /// The request's id as JSON, to answer it.
    rpc_id: []u8,
    title: []u8,
    options: []Option,
    chosen: ?usize = null,
};

/// A visual the agent showed (`show_visual`), live in its turn.
pub const Shown = struct { title: []u8, v: *visual.Visual };

/// An MCP server for the agent's session (ACP stdio form).
pub const McpServer = struct { name: []const u8, command: []const u8, args: []const []const u8 };

pub const Item = union(enum) {
    text: std.ArrayList(u8),
    thought: std.ArrayList(u8),
    tool: Tool,
    plan: std.ArrayList(PlanEntry),
    permission: Permission,
    command: *blocks.Block,
    note: []u8,
    visual: Shown,
};

/// A picture that goes with a prompt, as ACP sends one.
pub const Image = struct {
    name: []u8,
    /// "image/png", "image/jpeg", …: static.
    mime: []const u8,
    data: []u8,

    pub fn free(im: Image, gpa: std.mem.Allocator) void {
        gpa.free(im.name);
        gpa.free(im.data);
    }
};

pub const Turn = struct {
    prompt: []u8,
    /// The pictures sent with the prompt, owned.
    images: []Image = &.{},
    /// What the timeline shows instead of a long prompt ("Fix `make`").
    title: ?[]u8 = null,
    agent: Which,
    items: std.ArrayList(Item) = .empty,
    done: bool = false,
    started: f64,
    ended: f64 = 0,
    /// Which folded groups of steps are open (view_fold.zig), by order.
    open_groups: u64 = 0,
};

/// What the agent needs from the app around it.
pub const App = struct {
    ctx: *anyopaque,
    changed: *const fn (ctx: *anyopaque) void,
    /// A block for a command the agent runs, which the app keeps.
    newBlock: *const fn (ctx: *anyopaque, command: []const u8, cwd: []const u8) ?*blocks.Block,
    /// A turn ended (for the session history).
    finished: ?*const fn (ctx: *anyopaque, t: *Turn) void = null,
};

pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: App,
    which: Which,
    client: acp.Client,
    status: Status = .off,
    session: ?[]u8 = null,
    cwd: []u8,
    turns: std.ArrayList(*Turn) = .empty,
    terminals: host.Terminals,
    error_text: ?[]u8 = null,
    /// A prompt sent before the session was ready waits here.
    queued: ?[]u8 = null,
    /// The agent takes images in prompts (`promptCapabilities.image`).
    images_ok: bool = false,
    /// The environment of the commands it runs, "KEY=value" (the app's).
    env: []const []const u8 = &.{},
    /// What the agent lets the user choose: model, mode, slash commands.
    config: agent_config.Config,
    /// The SSH host its pane is on, if it is: its commands and files
    /// are the host's (agent_remote.zig).
    remote: ?@import("agent_remote.zig").Remote = null,
    /// nanoterm's own MCP server (show_visual), given to the session.
    mcp: ?McpServer = null,
    /// Called when the agent goes, to stop routing visuals to it.
    on_destroy: ?struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, a: *Agent) void } = null,
    msg_buf: [512]u8 = undefined,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, app: App, which: Which, cwd: []const u8) !*Agent {
        const a = try gpa.create(Agent);
        a.* = .{
            .gpa = gpa,
            .io = io,
            .app = app,
            .which = which,
            .client = undefined,
            .cwd = try gpa.dupe(u8, cwd),
            .terminals = .init(gpa),
            .config = .{ .gpa = gpa },
        };
        a.client = .init(gpa, .{ .ctx = a, .request = host.onRequest, .notification = onNotification, .exited = onExited });
        return a;
    }

    pub fn destroy(a: *Agent) void {
        if (a.on_destroy) |d| d.func(d.ctx, a);
        if (a.remote) |r| r.deinit(a.gpa);
        a.client.deinit();
        a.terminals.deinit();
        a.config.deinit();
        for (a.turns.items) |t| freeTurn(a.gpa, t);
        a.turns.deinit(a.gpa);
        if (a.session) |s| a.gpa.free(s);
        if (a.error_text) |e| a.gpa.free(e);
        if (a.queued) |q| a.gpa.free(q);
        a.gpa.free(a.cwd);
        a.gpa.destroy(a);
    }

    fn freeTurn(gpa: std.mem.Allocator, t: *Turn) void {
        for (t.items.items) |*it| switch (it.*) {
            .text, .thought => |*l| l.deinit(gpa),
            .tool => |*tl| {
                gpa.free(tl.id);
                gpa.free(tl.kind);
                tl.title.deinit(gpa);
                tl.detail.deinit(gpa);
            },
            .plan => |*p| {
                for (p.items) |e| {
                    gpa.free(e.text);
                    gpa.free(e.status);
                }
                p.deinit(gpa);
            },
            .permission => |p| {
                gpa.free(p.rpc_id);
                gpa.free(p.title);
                for (p.options) |o| {
                    gpa.free(o.id);
                    gpa.free(o.name);
                    gpa.free(o.kind);
                }
                gpa.free(p.options);
            },
            .note => |n| gpa.free(n),
            .visual => |sv| {
                gpa.free(sv.title);
                sv.v.destroy();
            },
            .command => {},
        };
        t.items.deinit(gpa);
        gpa.free(t.prompt);
        for (t.images) |im| im.free(gpa);
        if (t.images.len > 0) gpa.free(t.images);
        if (t.title) |x| gpa.free(x);
        gpa.destroy(t);
    }

    /// Starts the agent's process with `argv` and opens a session.
    pub fn start(a: *Agent, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) !void {
        a.status = .starting;
        const cwd_z = try a.gpa.dupeSentinel(u8, a.cwd, 0);
        defer a.gpa.free(cwd_z);
        a.client.start(argv, envp, cwd_z) catch |err| {
            a.fail("could not start the agent: {s}", .{@errorName(err)});
            return err;
        };
        try a.client.request("initialize", .{
            .protocolVersion = acp.protocol_version,
            .clientCapabilities = .{ .fs = .{ .readTextFile = true, .writeTextFile = true }, .terminal = true },
            .clientInfo = .{ .name = "nanoterm", .version = "0.1.0" },
        }, a, onInitialized);
    }

    fn fail(a: *Agent, comptime fmt: []const u8, args: anytype) void {
        a.status = .failed;
        if (a.error_text) |e| a.gpa.free(e);
        // The agent's own last words say most: add them.
        const said = a.client.stderr.lastLine();
        a.error_text = if (said.len > 0)
            std.fmt.allocPrint(a.gpa, fmt ++ " — {s}", args ++ .{said}) catch null
        else
            std.fmt.allocPrint(a.gpa, fmt, args) catch null;
        if (a.turns.items.len > 0) {
            const t = a.turns.items[a.turns.items.len - 1];
            if (!t.done) {
                if (a.error_text) |e| a.addItem(t, .{ .note = a.gpa.dupe(u8, e) catch return });
                t.done = true;
                t.ended = blocks.now();
            }
        }
        a.app.changed(a.app.ctx);
    }

    fn onInitialized(ctx: *anyopaque, result: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (err) |e| return a.fail("the agent did not start: {s}", .{e});
        const caps = acp.obj(acp.obj(result orelse .null, "agentCapabilities") orelse .null, "promptCapabilities") orelse .null;
        if (acp.obj(caps, "image")) |v| a.images_ok = v == .bool and v.bool;
        const Env = struct { name: []const u8, value: []const u8 };
        const Server = struct { name: []const u8, command: []const u8, args: []const []const u8, env: []const Env = &.{} };
        const servers: []const Server = if (a.mcp) |m| &.{.{ .name = m.name, .command = m.command, .args = m.args }} else &.{};
        a.client.request("session/new", .{ .cwd = a.cwd, .mcpServers = servers }, a, onSession) catch {};
    }

    fn onSession(ctx: *anyopaque, result: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (err) |e| return a.fail("no session: {s} (is the agent signed in?)", .{e});
        const id = acp.str(result orelse .null, "sessionId") orelse return a.fail("no session id", .{});
        a.session = a.gpa.dupe(u8, id) catch return;
        if (acp.obj(result.?, "configOptions")) |opts| a.config.setOptions(opts);
        a.status = .ready;
        if (a.queued) |q| {
            a.queued = null;
            defer a.gpa.free(q);
            a.send(q, if (a.current()) |t| t.images else &.{});
        }
        a.app.changed(a.app.ctx);
    }

    /// Starts a turn with `text`; it runs once the session is open.
    pub fn prompt(a: *Agent, text: []const u8) !void {
        return a.promptAs(null, text);
    }

    /// A turn whose timeline shows `title` rather than all of `text`.
    pub fn promptAs(a: *Agent, title: ?[]const u8, text: []const u8) !void {
        return a.promptWith(title, text, &.{});
    }

    /// A turn with pictures; it owns `images` (allocated with `gpa`), even
    /// when it fails.
    pub fn promptWith(a: *Agent, title: ?[]const u8, text: []const u8, images: []Image) !void {
        const t = a.gpa.create(Turn) catch |err| {
            for (images) |im| im.free(a.gpa);
            if (images.len > 0) a.gpa.free(images);
            return err;
        };
        t.* = .{
            .prompt = &.{},
            .images = images,
            .agent = a.which,
            .started = blocks.now(),
        };
        {
            errdefer freeTurn(a.gpa, t);
            t.prompt = try a.gpa.dupe(u8, text);
            if (title) |x| t.title = try a.gpa.dupe(u8, x);
            try a.turns.append(a.gpa, t);
        }
        if (a.status == .failed) {
            a.addItem(t, .{ .note = try a.gpa.dupe(u8, a.error_text orelse "the agent is not running") });
            t.done = true;
            return;
        }
        if (a.session == null) {
            if (a.queued) |q| a.gpa.free(q);
            a.queued = try a.gpa.dupe(u8, text);
            return;
        }
        a.send(text, images);
    }

    fn send(a: *Agent, text: []const u8, images: []const Image) void {
        a.status = .working;
        var parts: std.ArrayList(Part) = .empty;
        defer parts.deinit(a.gpa);
        parts.append(a.gpa, .{ .text = text }) catch return;
        if (images.len > 0 and !a.images_ok) {
            if (a.current()) |t| a.addItem(t, .{ .note = std.fmt.allocPrint(a.gpa, "{s} does not take images: the text went alone", .{a.which.label()}) catch return });
        } else for (images) |*im| parts.append(a.gpa, .{ .image = im }) catch return;
        a.client.request("session/prompt", .{ .sessionId = a.session.?, .prompt = parts.items }, a, onPromptDone) catch {};
    }

    /// A content block of a prompt: text, or an image in base64.
    const Part = struct {
        text: []const u8 = "",
        image: ?*const Image = null,

        pub fn jsonStringify(p: Part, jw: anytype) !void {
            try jw.beginObject();
            try jw.objectField("type");
            if (p.image) |im| {
                try jw.write("image");
                try jw.objectField("mimeType");
                try jw.write(im.mime);
                try jw.objectField("data");
                try jw.beginWriteRaw();
                try jw.writer.writeByte('"');
                try std.base64.standard.Encoder.encodeWriter(jw.writer, im.data);
                try jw.writer.writeByte('"');
                jw.endWriteRaw();
            } else {
                try jw.write("text");
                try jw.objectField("text");
                try jw.write(p.text);
            }
            try jw.endObject();
        }
    };

    fn onPromptDone(ctx: *anyopaque, result: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        const t = a.current() orelse return;
        if (err) |e| a.addItem(t, .{ .note = std.fmt.allocPrint(a.gpa, "error: {s}", .{e}) catch return });
        if (acp.str(result orelse .null, "stopReason")) |r| {
            if (std.mem.eql(u8, r, "cancelled")) a.addItem(t, .{ .note = a.gpa.dupe(u8, "cancelled") catch return });
        }
        t.done = true;
        t.ended = blocks.now();
        if (a.status == .working) a.status = .ready;
        if (a.app.finished) |f| f(a.app.ctx, t);
        a.app.changed(a.app.ctx);
    }

    /// Chooses `value` for the config option `id` (a model, a mode).
    pub fn setOption(a: *Agent, id: []const u8, value: []const u8) void {
        const s = a.session orelse return;
        a.config.setCurrent(id, value);
        a.client.request("session/set_config_option", .{ .sessionId = s, .configId = id, .value = value }, a, onOptionSet) catch {};
        a.app.changed(a.app.ctx);
    }

    fn onOptionSet(ctx: *anyopaque, result: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (err == null) if (acp.obj(result orelse .null, "configOptions")) |opts| a.config.setOptions(opts);
        a.app.changed(a.app.ctx);
    }

    /// Stops the turn running.
    pub fn cancel(a: *Agent) void {
        const s = a.session orelse return;
        a.client.notify("session/cancel", .{ .sessionId = s }) catch {};
    }

    pub fn current(a: *Agent) ?*Turn {
        if (a.turns.items.len == 0) return null;
        return a.turns.items[a.turns.items.len - 1];
    }

    pub fn addItem(a: *Agent, t: *Turn, item: Item) void {
        t.items.append(a.gpa, item) catch {};
    }

    /// Shows a visual in the turn running; null, or why it was not shown.
    /// Setup and the first render must work, as Harness checks.
    pub fn showVisual(a: *Agent, title: []const u8, script: []const u8) ?[]const u8 {
        if (visual.validate(title, script)) |e| return e;
        const t = a.current() orelse return "show_visual needs an active turn";
        if (t.done) return "show_visual needs an active turn";
        const v = visual.Visual.create(a.gpa, script) catch return "out of memory";
        if (v.err) |e| {
            const msg = std.fmt.bufPrint(&a.msg_buf, "the visual did not render: {s}", .{e}) catch "the visual did not render";
            v.destroy();
            return msg;
        }
        const owned = a.gpa.dupe(u8, std.mem.trim(u8, title, " \t\r\n")) catch {
            v.destroy();
            return "out of memory";
        };
        t.items.append(a.gpa, .{ .visual = .{ .title = owned, .v = v } }) catch {
            a.gpa.free(owned);
            v.destroy();
            return "out of memory";
        };
        a.app.changed(a.app.ctx);
        return null;
    }

    /// Answers a permission question with option `index`.
    pub fn answer(a: *Agent, p: *Permission, index: usize) void {
        if (p.chosen != null or index >= p.options.len) return;
        p.chosen = index;
        a.client.respond(p.rpc_id, .{ .outcome = .{ .outcome = "selected", .optionId = p.options[index].id } });
        a.app.changed(a.app.ctx);
    }

    fn onExited(ctx: *anyopaque, code: i32) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        a.session = null;
        a.fail("the agent exited (code {d})", .{code});
    }

    fn appendChunk(a: *Agent, t: *Turn, thought: bool, text: []const u8) void {
        if (t.items.items.len > 0) {
            const last = &t.items.items[t.items.items.len - 1];
            switch (last.*) {
                .text => |*l| if (!thought) return l.appendSlice(a.gpa, text) catch {},
                .thought => |*l| if (thought) return l.appendSlice(a.gpa, text) catch {},
                else => {},
            }
        }
        var l: std.ArrayList(u8) = .empty;
        l.appendSlice(a.gpa, text) catch return;
        a.addItem(t, if (thought) .{ .thought = l } else .{ .text = l });
    }

    fn tool(t: *Turn, id: []const u8) ?*Tool {
        for (t.items.items) |*it| switch (it.*) {
            .tool => |*tl| if (std.mem.eql(u8, tl.id, id)) return tl,
            else => {},
        };
        return null;
    }

    fn updateTool(a: *Agent, tl: *Tool, u: std.json.Value) void {
        if (acp.str(u, "title")) |title| {
            tl.title.clearRetainingCapacity();
            tl.title.appendSlice(a.gpa, title) catch {};
        }
        if (acp.str(u, "status")) |s| tl.status = std.meta.stringToEnum(ToolStatus, s) orelse tl.status;
        const content = acp.obj(u, "content") orelse return;
        if (content != .array) return;
        for (content.array.items) |c| {
            const kind = acp.str(c, "type") orelse continue;
            if (std.mem.eql(u8, kind, "terminal")) {
                if (acp.str(c, "terminalId")) |tid| tl.block = a.terminals.block(tid);
            } else if (std.mem.eql(u8, kind, "diff")) {
                tl.detail.clearRetainingCapacity();
                tl.detail.appendSlice(a.gpa, acp.str(c, "path") orelse "") catch {};
            } else if (std.mem.eql(u8, kind, "content")) {
                if (acp.str(acp.obj(c, "content") orelse .null, "text")) |text| {
                    tl.detail.clearRetainingCapacity();
                    tl.detail.appendSlice(a.gpa, text[0..@min(text.len, 2000)]) catch {};
                }
            }
        }
    }

    fn onNotification(ctx: *anyopaque, method: []const u8, params: std.json.Value, _: std.mem.Allocator) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, method, "session/update")) return;
        const u = acp.obj(params, "update") orelse return;
        const kind = acp.str(u, "sessionUpdate") orelse return;
        defer a.app.changed(a.app.ctx);
        // What the agent offers comes before any turn.
        if (std.mem.eql(u8, kind, "available_commands_update")) {
            if (acp.obj(u, "availableCommands")) |list| a.config.setCommands(list);
            return;
        } else if (std.mem.eql(u8, kind, "config_option_update")) {
            if (acp.obj(u, "configOptions")) |opts| a.config.setOptions(opts);
            return;
        } else if (std.mem.eql(u8, kind, "current_mode_update")) {
            if (a.config.find("mode")) |o| if (acp.str(u, "currentModeId")) |m| a.config.setCurrent(o.id, m);
            return;
        }
        const t = a.current() orelse return;
        if (std.mem.eql(u8, kind, "agent_message_chunk") or std.mem.eql(u8, kind, "agent_thought_chunk")) {
            const text = acp.str(acp.obj(u, "content") orelse .null, "text") orelse return;
            a.appendChunk(t, kind[6] == 't', text);
        } else if (std.mem.eql(u8, kind, "tool_call")) {
            const id = acp.str(u, "toolCallId") orelse return;
            if (tool(t, id)) |tl| return a.updateTool(tl, u);
            const new: Tool = .{
                .id = a.gpa.dupe(u8, id) catch return,
                .kind = a.gpa.dupe(u8, acp.str(u, "kind") orelse "other") catch return,
            };
            a.addItem(t, .{ .tool = new });
            a.updateTool(&t.items.items[t.items.items.len - 1].tool, u);
        } else if (std.mem.eql(u8, kind, "tool_call_update")) {
            const id = acp.str(u, "toolCallId") orelse return;
            if (tool(t, id)) |tl| a.updateTool(tl, u);
        } else if (std.mem.eql(u8, kind, "plan")) {
            const entries = acp.obj(u, "entries") orelse return;
            if (entries != .array) return;
            var list: std.ArrayList(PlanEntry) = .empty;
            for (entries.array.items) |e| list.append(a.gpa, .{
                .text = a.gpa.dupe(u8, acp.str(e, "content") orelse "") catch continue,
                .status = a.gpa.dupe(u8, acp.str(e, "status") orelse "pending") catch continue,
            }) catch {};
            // One plan per turn, replaced as it changes.
            for (t.items.items) |*it| switch (it.*) {
                .plan => |*p| {
                    for (p.items) |e| {
                        a.gpa.free(e.text);
                        a.gpa.free(e.status);
                    }
                    p.deinit(a.gpa);
                    p.* = list;
                    return;
                },
                else => {},
            };
            a.addItem(t, .{ .plan = list });
        }
    }
};
