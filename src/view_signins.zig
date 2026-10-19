//! graff's own sign-ins, under graff in Settings' agents (and onboarding's):
//! bring a ChatGPT, xAI, Kimi or Z.ai account and graff runs on your plan,
//! no credits needed. Each signs in with `graff login <provider>` in a new
//! tab (the browser opens). Whether one is signed in comes from graff's
//! models over ACP (catalog.zig: only signed-in providers' models), once
//! graff has said; until then each simply offers its sign-in.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const marks = @import("marks.zig");
const catalog = @import("catalog.zig");
const Workspace = @import("workspace.zig").Workspace;

pub const Provider = struct {
    name: []const u8,
    login: []const u8,
    lab: []const u8,
    /// graff's provider ids for it.
    ids: []const []const u8,
};

pub const providers = [_]Provider{
    .{ .name = "ChatGPT", .login = "graff login chatgpt", .lab = "openai", .ids = &.{ "chatgpt", "chatgpt-new", "codex" } },
    .{ .name = "xAI", .login = "graff login xai", .lab = "xai", .ids = &.{"xai"} },
    .{ .name = "Kimi", .login = "graff login kimi", .lab = "moonshot", .ids = &.{"kimi"} },
    .{ .name = "Z.ai", .login = "graff login zai", .lab = "zai", .ids = &.{"zai"} },
};

/// Signed in, not, or not known yet (graff hasn't listed its models).
pub fn signedIn(cat: *const catalog.Catalog, p: Provider) ?bool {
    if (cat.acp != .answered) return null;
    for (cat.models.items) |m| for (p.ids) |id| {
        if (std.mem.eql(u8, m.provider, id)) return true;
    };
    return false;
}

/// The sign-ins, under graff's row; `run` starts a command in a new tab.
pub fn list(c: *ui.Context, w: *Workspace, comptime run: fn (*Workspace, []const u8) void) void {
    const box = ui.div(c).column().wFull().gap(10).pl(33).pb(4);
    defer box.end();
    {
        const t = ui.div(c).column().gap(2);
        defer t.end();
        ui.text(c, "Bring your own sign-ins", .{ .size = 12.5, .weight = .semibold });
        ui.text(c, "graff runs on your plan with any of these, no credits needed.", .{ .size = 11.5, .color = theme.muted });
    }
    const row = ui.div(c).row().gap(6);
    defer row.end();
    for (providers) |p| {
        ui.key(c, c.print("signin-{s}", .{p.lab}));
        const on = signedIn(&w.shared.catalog, p) orelse false;
        var chip = ui.div(c).row().gap(6).itemsCenter().px(9).py(6).rounded(8).border(if (on) theme.success.alpha(0.5) else theme.border);
        chip = if (on) chip.bg(theme.success.alpha(0.08)) else chip.control().hover(theme.block_hover);
        defer chip.end();
        if (!on and chip.clicked()) run(w, p.login);
        if (marks.of(p.lab)) |png| _ = ui.image(c, .{ .key = c.print("signin-mark-{s}", .{p.lab}), .bytes = png, .max_width = 14, .max_height = 14, .radius = 0, .tint = theme.text });
        ui.text(c, if (on) c.print("{s} · signed in", .{p.name}) else c.print("Sign in with {s}", .{p.name}), .{ .size = 12, .weight = .medium, .color = if (on) theme.success else theme.text });
    }
}

test "a provider is signed in when graff lists its models" {
    var cat: catalog.Catalog = .{ .gpa = std.testing.allocator };
    defer cat.deinit();
    try std.testing.expect(signedIn(&cat, providers[0]) == null);
    const json =
        \\{"models":[{"provider":"chatgpt-new","name":"gpt","authenticated":true,"cost":"plan"},
        \\ {"provider":"zai","name":"glm","authenticated":true,"cost":"plan"},
        \\ {"provider":"xai","name":"grok","authenticated":false,"cost":"plan"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try cat.fromAcp(parsed.value);
    cat.acp = .answered;
    try std.testing.expectEqual(@as(?bool, true), signedIn(&cat, providers[0]));
    try std.testing.expectEqual(@as(?bool, false), signedIn(&cat, providers[1]));
    try std.testing.expectEqual(@as(?bool, false), signedIn(&cat, providers[2]));
    try std.testing.expectEqual(@as(?bool, true), signedIn(&cat, providers[3]));
}
