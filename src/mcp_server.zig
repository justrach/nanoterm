//! nanoterm's MCP server, which an agent starts as `nanoterm --mcp SOCKET
//! TOKEN` (nanoterm names it in ACP's `mcpServers`). It offers one tool,
//! `show_visual`, as Harness's: the script is checked here (setup and first
//! render), then sent to nanoterm (visual_host.zig), which shows it in the
//! agent's turn. MCP over stdio: JSON-RPC, a message per line.
const std = @import("std");
const visual = @import("visual.zig");
const host = @import("visual_host.zig");

extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;

pub const description =
    "Show an interactive native visual inline in this nanoterm conversation: a small tool the user can explore " ++
    "(walk through how a system works, compare options, adjust assumptions) without another model turn. Provide a " ++
    "short title and Luau source returning a render function, e.g. return function() return ui.text(\"Hello\") end. " ++
    "Constructors: ui.column, row, group, heading, text, note, stat, chart, flow, tabs, list, table, code, badge, " ++
    "progress, button, toggle, slider, rule. Show structure, not paragraphs: a flow for a pipeline, tabs to switch " ++
    "views, a table or list for parts, stats and charts for numbers, short text. No HTML, styling, files, or " ++
    "network. Setup and the first render are checked in an isolated bounded runtime before it is shown. This does " ++
    "not send a message.";

pub const script_description =
    "Luau source, nonblank, at most 64 KiB UTF-8. Initialize state in locals and return function() return <node> end. " ++
    "Layout: ui.column{nodes...}, ui.row{nodes...}, ui.group{title='Platform layer', nodes...} (a titled panel), ui.rule{}. " ++
    "Text: ui.heading('Section'), ui.text('A sentence or two'), ui.note('Small muted caption'), ui.code('src/ui/layout.zig'), " ++
    "ui.badge{label='macOS', tone='success'} (tone: neutral, accent, success, warning, danger). " ++
    "Data: ui.stat{label='Count',value=42}, ui.chart{label='Trend',values={1,2},labels={'A','B'}} (bars), " ++
    "ui.progress{label='Done',value=3,max=5}, ui.list{items={'a','b'},ordered=false}, " ++
    "ui.table{columns={'File','Role'},rows={{'surface.zig','events'},{'layout.zig','flexbox'}}}. " ++
    "Explaining: ui.flow{label='One frame',steps={'Event','View','Layout','Paint'},active=step,onSelect=function(i) step = i end} " ++
    "(numbered steps with the active one lit; positions start at 1), " ++
    "ui.tabs{options={'Native UI','Web'},value=tab,onChange=function(i) tab = i end}. " ++
    "Controls: ui.button{label='Add',onClick=function() ... end}, ui.toggle{label='Enabled',value=false,onChange=function(v) ... end}, " ++
    "ui.slider{label='Target',value=3,min=0,max=10,onChange=function(v) ... end}. " ++
    "A good explainer: tabs for the views, a flow whose selected step shows a group with a heading, a short text, a " ++
    "table or list of the files involved, and badges. Only these properties; no CSS/style/HTML or external assets. " ++
    "Callbacks update locals; the host re-renders without model calls. State is temporary. Dense arrays and finite " ++
    "numbers only. Per render: 512 nodes, depth 24, 8 KiB total text, 256 chart values. Libraries: string, table, " ++
    "math, utf8 (no io, os, require). Keep handlers small. Use clear labels and units; label synthetic estimates.";

/// Answers one message (a line); null when it needs no answer. `send`
/// gives a checked visual to nanoterm and returns its reply.
pub fn handle(gpa: std.mem.Allocator, line: []const u8, send: anytype) ?[]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const msg = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch return null;
    if (msg != .object) return null;
    const id = msg.object.get("id") orelse return null; // a notification
    const method = if (msg.object.get("method")) |m| (if (m == .string) m.string else "") else "";
    const params = msg.object.get("params") orelse .null;
    if (std.mem.eql(u8, method, "initialize")) {
        const asked = if (params == .object) params.object.get("protocolVersion") else null;
        const version = if (asked) |v| (if (v == .string) v.string else "2025-06-18") else "2025-06-18";
        return reply(gpa, id, .{
            .protocolVersion = version,
            .capabilities = .{ .tools = Empty{} },
            .serverInfo = .{ .name = "nanoterm", .version = "0.1.0" },
        });
    }
    if (std.mem.eql(u8, method, "ping")) return reply(gpa, id, Empty{});
    if (std.mem.eql(u8, method, "tools/list")) {
        const Prop = struct { type: []const u8 = "string", minLength: u32 = 1, maxLength: u32, description: ?[]const u8 = null };
        return reply(gpa, id, .{ .tools = .{.{
            .name = "show_visual",
            .description = description,
            .inputSchema = .{
                .type = "object",
                .additionalProperties = false,
                .properties = .{ .title = Prop{ .maxLength = 200 }, .script = Prop{ .maxLength = 65536, .description = script_description } },
                .required = .{ "title", "script" },
            },
        }} });
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const text, const failed = call(a, params, send);
        return reply(gpa, id, .{ .content = .{.{ .type = "text", .text = text }}, .isError = failed });
    }
    return std.json.Stringify.valueAlloc(gpa, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = -32601, .message = "method not found" } }, .{}) catch null;
}

/// `{}` in JSON: an empty `.{}` is a tuple, which is written as `[]`, and
/// MCP clients that check types (Kiro's) refuse it.
const Empty = struct {};

fn reply(gpa: std.mem.Allocator, id: std.json.Value, result: anytype) ?[]u8 {
    return std.json.Stringify.valueAlloc(gpa, .{ .jsonrpc = "2.0", .id = id, .result = result }, .{ .emit_null_optional_fields = false }) catch null;
}

fn call(a: std.mem.Allocator, params: std.json.Value, send: anytype) struct { []const u8, bool } {
    const name = if (params == .object) if (params.object.get("name")) |n| (if (n == .string) n.string else "") else "" else "";
    if (!std.mem.eql(u8, name, "show_visual")) return .{ "unknown tool", true };
    const args = if (params == .object) params.object.get("arguments") orelse .null else .null;
    if (args != .object) return .{ "invalid arguments: expected title and script", true };
    var it = args.object.iterator();
    while (it.next()) |e| if (!std.mem.eql(u8, e.key_ptr.*, "title") and !std.mem.eql(u8, e.key_ptr.*, "script"))
        return .{ std.fmt.allocPrint(a, "invalid arguments: unknown field '{s}'", .{e.key_ptr.*}) catch "invalid arguments", true };
    const title = args.object.get("title") orelse .null;
    const script = args.object.get("script") orelse .null;
    if (title != .string or script != .string) return .{ "invalid arguments: title and script must be strings", true };
    if (visual.validate(title.string, script.string)) |e| return .{ e, true };
    // Check it here first: the agent hears what is wrong at once.
    const v = visual.Visual.create(a, script.string) catch return .{ "out of memory", true };
    defer v.destroy();
    if (v.err) |e| return .{ std.fmt.allocPrint(a, "the visual did not render: {s}", .{e}) catch "the visual did not render", true };
    return send.send(a, title.string, script.string);
}

/// Sends a checked visual to nanoterm over its socket.
pub const Sender = struct {
    path: []const u8,
    token: []const u8,

    pub fn send(s: Sender, a: std.mem.Allocator, title: []const u8, script: []const u8) struct { []const u8, bool } {
        const fd = host.dial(s.path) catch return .{ "nanoterm is not reachable (was it closed?)", true };
        defer _ = close(fd);
        const line = std.json.Stringify.valueAlloc(a, .{ .token = s.token, .title = title, .script = script }, .{}) catch return .{ "out of memory", true };
        if (!host.writeAll(fd, line) or !host.writeAll(fd, "\n")) return .{ "nanoterm is not reachable", true };
        var buf: std.ArrayList(u8) = .empty;
        host.readLine(a, fd, &buf) catch return .{ "nanoterm did not answer", true };
        const Reply = struct { ok: bool, message: []const u8 };
        const r = std.json.parseFromSliceLeaky(Reply, a, buf.items, .{}) catch return .{ "nanoterm answered oddly", true };
        return .{ r.message, !r.ok };
    }
};

/// The server's loop: stdin to stdout until stdin ends.
pub fn serve(gpa: std.mem.Allocator, path: []const u8, token: []const u8) void {
    const sender: Sender = .{ .path = path, .token = token };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        while (std.mem.indexOfScalar(u8, buf.items, '\n')) |nl| {
            const line = std.mem.trim(u8, buf.items[0..nl], " \r");
            if (line.len > 0) if (handle(gpa, line, sender)) |answer| {
                defer gpa.free(answer);
                _ = host.writeAll(1, answer);
                _ = host.writeAll(1, "\n");
            };
            const rest = buf.items.len - nl - 1;
            std.mem.copyForwards(u8, buf.items[0..rest], buf.items[nl + 1 ..]);
            buf.items.len = rest;
        }
        const n = read(0, &chunk, chunk.len);
        if (n <= 0) return;
        buf.appendSlice(gpa, chunk[0..@intCast(n)]) catch return;
    }
}
