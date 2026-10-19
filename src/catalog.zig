//! graff's models, for the model picker. Over ACP (`graff/models`, as
//! Harness asks): the models of the providers signed in, each with its
//! maker and how it is paid for (your plan, local, Codegraff's credits,
//! your own key); grouped by provider, the plans first, as Harness lists
//! them. Until graff's session is up, `graff models` (its live catalog by
//! provider, read once in the background) stands in.
const std = @import("std");
const proc = @import("proc.zig");

pub const Model = struct {
    provider: []const u8,
    name: []const u8,
    /// Context window and price, as graff prints them.
    detail: []const u8,
    /// Who makes it (`anthropic`, `moonshot`…), and how it is paid for:
    /// `plan`, `local`, `credits` or `api` (from ACP only).
    maker: []const u8 = "",
    cost: []const u8 = "",
    current: bool = false,
};

/// How a provider's models are paid for, in the order Harness lists them:
/// your plan logins first, then local models, credits, your own keys.
pub fn costRank(cost: []const u8) u8 {
    if (std.mem.eql(u8, cost, "plan")) return 0;
    if (std.mem.eql(u8, cost, "local")) return 1;
    if (std.mem.eql(u8, cost, "api")) return 3;
    return 2;
}

/// After a section's name: "Codex · your plan".
pub fn costNote(cost: []const u8) []const u8 {
    if (std.mem.eql(u8, cost, "plan")) return "your plan";
    if (std.mem.eql(u8, cost, "local")) return "local";
    if (std.mem.eql(u8, cost, "credits")) return "credits";
    if (std.mem.eql(u8, cost, "api")) return "your key";
    return "";
}

/// A provider's name in a section's title.
pub fn providerName(p: []const u8) []const u8 {
    const names = [_][2][]const u8{
        .{ "anthropic", "Anthropic" }, .{ "codegraff", "Codegraff" }, .{ "codex", "Codex" },       .{ "chatgpt", "ChatGPT" },
        .{ "chatgpt-new", "ChatGPT" }, .{ "deepseek", "DeepSeek" },   .{ "kimi", "Kimi" },         .{ "lmstudio", "LM Studio" },
        .{ "mlx", "MLX" },             .{ "openai", "OpenAI" },       .{ "openrouter", "OpenRouter" }, .{ "xai", "xAI" },
        .{ "xiaomi", "Xiaomi" },       .{ "zai", "Z.ai" },            .{ "cerebras", "Cerebras" },
    };
    for (names) |n| if (std.mem.eql(u8, n[0], p)) return n[1];
    return p;
}

pub const Catalog = struct {
    gpa: std.mem.Allocator,
    state: enum { idle, loading, ready, failed } = .idle,
    models: std.ArrayList(Model) = .empty,
    text: std.ArrayList(u8) = .empty,
    process: proc.Process = undefined,
    changed: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque) void } = null,
    /// graff's session was asked (`graff/models`), and answered.
    acp: enum { none, asked, answered } = .none,
    /// The ACP rows' strings.
    strings: ?std.heap.ArenaAllocator = null,

    pub fn deinit(c: *Catalog) void {
        if (c.state == .loading) c.process.close();
        c.models.deinit(c.gpa);
        c.text.deinit(c.gpa);
        if (c.strings) |*a| a.deinit();
    }

    /// graff's answer to `graff/models` (an ACP callback).
    pub fn onAcp(ctx: *anyopaque, result: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const c: *Catalog = @ptrCast(@alignCast(ctx));
        if (err != null) {
            c.acp = .answered;
            return;
        }
        c.fromAcp(result orelse .null) catch {};
        c.acp = .answered;
        if (c.changed) |ch| ch.func(ch.ctx);
    }

    /// The rows of the providers signed in, grouped by provider, plans
    /// first (stable: a provider's place among its kind is where it came).
    pub fn fromAcp(c: *Catalog, v: std.json.Value) !void {
        const rows = if (v == .object) v.object.get("models") orelse return else return;
        if (rows != .array) return;
        if (c.strings) |*a| a.deinit();
        c.strings = .init(c.gpa);
        const a = c.strings.?.allocator();
        var list: std.ArrayList(Model) = .empty;
        for (rows.array.items) |r| {
            if (r != .object) continue;
            const o = r.object;
            const authed = o.get("authenticated") orelse continue;
            if (authed != .bool or !authed.bool) continue;
            const str = struct {
                fn f(obj: std.json.ObjectMap, key: []const u8) []const u8 {
                    const x = obj.get(key) orelse return "";
                    return if (x == .string) x.string else "";
                }
            }.f;
            const provider = str(o, "provider");
            const name = str(o, "name");
            if (provider.len == 0 or name.len == 0) continue;
            const ctx_tokens: u64 = if (o.get("context")) |x| (if (x == .integer and x.integer > 0) @intCast(x.integer) else 0) else 0;
            const cur = if (o.get("current")) |x| x == .bool and x.bool else false;
            try list.append(a, .{
                .provider = try a.dupe(u8, provider),
                .name = try a.dupe(u8, name),
                .detail = if (ctx_tokens > 0) try std.fmt.allocPrint(a, "{d}k context", .{ctx_tokens / 1000}) else "",
                .maker = try a.dupe(u8, str(o, "maker")),
                .cost = try a.dupe(u8, str(o, "cost")),
                .current = cur,
            });
        }
        if (list.items.len == 0) return;
        // Sections by how they're paid (plans first), then where each
        // provider first appears; the current model's provider leads its kind.
        var order: std.ArrayList([]const u8) = .empty;
        for (list.items) |m| {
            for (order.items) |p| {
                if (std.mem.eql(u8, p, m.provider)) break;
            } else try order.append(a, m.provider);
        }
        const first = try a.dupe([]const u8, order.items);
        const Ctx = struct {
            list: []const Model,
            first: []const []const u8,
            fn rank(x: @This(), p: []const u8) usize {
                var cost: []const u8 = "";
                var current = false;
                for (x.list) |m| if (std.mem.eql(u8, m.provider, p)) {
                    if (cost.len == 0) cost = m.cost;
                    current = current or m.current;
                };
                const at = for (x.first, 0..) |q, k| {
                    if (std.mem.eql(u8, q, p)) break k;
                } else 0;
                return @as(usize, costRank(cost)) * 10_000 + (if (current) 0 else 1 + at);
            }
        };
        const cx: Ctx = .{ .list = list.items, .first = first };
        std.mem.sort([]const u8, order.items, cx, struct {
            fn lt(x: Ctx, l: []const u8, r: []const u8) bool {
                return x.rank(l) < x.rank(r);
            }
        }.lt);
        c.models.clearRetainingCapacity();
        for (order.items) |p| for (list.items) |m| if (std.mem.eql(u8, m.provider, p)) try c.models.append(c.gpa, m);
        c.state = .ready;
    }

    /// Starts `graff models` (once).
    pub fn load(c: *Catalog, arena: std.mem.Allocator, graff: []const u8, envp: [*:null]const ?[*:0]const u8) void {
        if (c.state != .idle) return;
        const argv = proc.cStrings(arena, &.{ graff, "models" }) catch return;
        proc.spawnPipes(&c.process, argv, envp, null, true, .{ .ctx = c, .output = onOutput, .exited = onExit }) catch {
            c.state = .failed;
            return;
        };
        c.process.closeInput();
        c.state = .loading;
    }

    fn onOutput(ctx: *anyopaque, bytes: []const u8) void {
        const c: *Catalog = @ptrCast(@alignCast(ctx));
        if (c.text.items.len < 1024 * 1024) c.text.appendSlice(c.gpa, bytes) catch {};
    }

    fn onExit(ctx: *anyopaque, code: i32) void {
        const c: *Catalog = @ptrCast(@alignCast(ctx));
        c.process.close();
        // graff's session answered already, with more: keep its rows.
        if (c.acp != .answered) {
            c.parse() catch {};
            c.state = if (code == 0 and c.models.items.len > 0) .ready else .failed;
        }
        if (c.changed) |ch| ch.func(ch.ctx);
    }

    /// Reads "provider:" headers and "  model   200000 ctx   $1/2 per 1M" lines.
    pub fn parse(c: *Catalog) !void {
        c.models.clearRetainingCapacity();
        var provider: []const u8 = "";
        var lines = std.mem.splitScalar(u8, c.text.items, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (line[0] != ' ') {
                provider = if (line[line.len - 1] == ':') line[0 .. line.len - 1] else "";
                continue;
            }
            if (provider.len == 0) continue;
            const t = std.mem.trim(u8, line, " ");
            const gap = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
            try c.models.append(c.gpa, .{
                .provider = provider,
                .name = t[0..gap],
                .detail = std.mem.trim(u8, t[gap..], " "),
            });
        }
    }
};

test "graff's catalog" {
    var c: Catalog = .{ .gpa = std.testing.allocator };
    defer c.deinit();
    try c.text.appendSlice(c.gpa, "model catalog — 3 entries\n\nanthropic:\n  claude-opus-5-5     1000000 ctx   $4/20 per 1M\n  claude-haiku-5-5   1000000 ctx   $0.1/0.5 per 1M\n\nlmstudio:\n  lmstudio   200000 ctx   (unpriced)\n");
    try c.parse();
    try std.testing.expectEqual(@as(usize, 3), c.models.items.len);
    try std.testing.expectEqualStrings("anthropic", c.models.items[1].provider);
    try std.testing.expectEqualStrings("claude-haiku-5-5", c.models.items[1].name);
    try std.testing.expectEqualStrings("1000000 ctx   $0.1/0.5 per 1M", c.models.items[1].detail);
    try std.testing.expectEqualStrings("lmstudio", c.models.items[2].provider);
}

test "graff's models over ACP: signed-in providers, plans first, grouped" {
    var c: Catalog = .{ .gpa = std.testing.allocator };
    defer c.deinit();
    const json =
        \\{"models":[
        \\ {"provider":"codegraff","name":"opus","maker":"anthropic","context":1000000,"authenticated":true,"cost":"credits"},
        \\ {"provider":"anthropic","name":"sonnet","maker":"anthropic","authenticated":true,"cost":"api"},
        \\ {"provider":"codex","name":"gpt","maker":"openai","context":272000,"authenticated":true,"cost":"plan","current":true},
        \\ {"provider":"openrouter","name":"x","authenticated":false,"cost":"api"},
        \\ {"provider":"codegraff","name":"kimi","maker":"moonshot","authenticated":true,"cost":"credits"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try c.fromAcp(parsed.value);
    try std.testing.expectEqual(@as(usize, 4), c.models.items.len);
    try std.testing.expectEqualStrings("codex", c.models.items[0].provider);
    try std.testing.expect(c.models.items[0].current);
    try std.testing.expectEqualStrings("272k context", c.models.items[0].detail);
    try std.testing.expectEqualStrings("codegraff", c.models.items[1].provider);
    try std.testing.expectEqualStrings("kimi", c.models.items[2].name);
    try std.testing.expectEqualStrings("anthropic", c.models.items[3].provider);
    try std.testing.expectEqualStrings("your plan", costNote(c.models.items[0].cost));
}
