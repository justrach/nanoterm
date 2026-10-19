//! The marks of the labs that make models, for the model picker, as
//! Harness draws them: monochrome, tinted with the text color. Anthropic's,
//! OpenAI's and xAI's are Harness's brand marks; the others are LobeHub
//! Icons (MIT; see THIRD_PARTY_NOTICES.md), drawn to PNG from their SVGs.
//! The agents' own marks are Harness's too.
const std = @import("std");

const table = [_]struct { []const u8, []const u8 }{
    .{ "anthropic", @embedFile("marks/claude-mark.png") },
    .{ "openai", @embedFile("marks/openai-mark.png") },
    .{ "xai", @embedFile("marks/grok-mark.png") },
    .{ "google", @embedFile("marks/gemini.png") },
    .{ "deepseek", @embedFile("marks/deepseek.png") },
    .{ "xiaomi", @embedFile("marks/mimo.png") },
    .{ "moonshot", @embedFile("marks/kimi.png") },
    .{ "zai", @embedFile("marks/zai.png") },
    .{ "alibaba", @embedFile("marks/qwen.png") },
    .{ "minimax", @embedFile("marks/minimax.png") },
    .{ "mistral", @embedFile("marks/mistral.png") },
    .{ "meta", @embedFile("marks/meta.png") },
};

/// An agent's own mark, as Harness shows it in its agent picker.
pub fn agent(which: @import("agent.zig").Which) []const u8 {
    return switch (which) {
        .graff => @embedFile("marks/graff-mark.png"),
        .claude => @embedFile("marks/claude-mark.png"),
        .codex => @embedFile("marks/openai-mark.png"),
        .opencode => @embedFile("marks/opencode-mark.png"),
        .grok => @embedFile("marks/grok-mark.png"),
        .devin => @embedFile("marks/devin-mark.png"),
        .hermes => @embedFile("marks/hermes-mark.png"),
    };
}

/// The maker's mark (a PNG), if there is one.
pub fn of(lab: []const u8) ?[]const u8 {
    for (table) |t| if (std.mem.eql(u8, t[0], lab)) return t[1];
    return null;
}

/// Who makes a model: what graff says, else read from its name (the last
/// path segment), else a provider that is itself a lab, as Harness reads it.
pub fn maker(said: []const u8, provider: []const u8, name_in: []const u8) []const u8 {
    if (said.len > 0) return said;
    const name = if (std.mem.lastIndexOfScalar(u8, name_in, '/')) |s| name_in[s + 1 ..] else name_in;
    const by_name = [_]struct { []const u8, []const u8 }{
        .{ "claude", "anthropic" }, .{ "gpt", "openai" },        .{ "codex", "openai" },  .{ "o3", "openai" },
        .{ "o4", "openai" },        .{ "grok", "xai" },          .{ "gemini", "google" }, .{ "gemma", "google" },
        .{ "deepseek", "deepseek" }, .{ "mimo", "xiaomi" },      .{ "kimi", "moonshot" }, .{ "k2", "moonshot" },
        .{ "glm", "zai" },          .{ "qwen", "alibaba" },      .{ "minimax", "minimax" }, .{ "mistral", "mistral" },
        .{ "devstral", "mistral" }, .{ "codestral", "mistral" }, .{ "llama", "meta" },
    };
    for (by_name) |b| if (std.ascii.startsWithIgnoreCase(name, b[0])) return b[1];
    for ([_][]const u8{ "anthropic", "openai", "xai", "google", "deepseek", "xiaomi", "zai", "alibaba", "minimax", "mistral", "meta" }) |lab| {
        if (std.mem.eql(u8, provider, lab)) return lab;
    }
    if (std.mem.eql(u8, provider, "codex") or std.mem.startsWith(u8, provider, "chatgpt")) return "openai";
    if (std.mem.eql(u8, provider, "kimi")) return "moonshot";
    return "";
}

test "makers and their marks" {
    try std.testing.expectEqualStrings("moonshot", maker("moonshot", "kimi", "kimi-for-coding"));
    try std.testing.expectEqualStrings("anthropic", maker("", "codegraff", "claude-opus-5-5"));
    try std.testing.expectEqualStrings("alibaba", maker("", "mlx", "mlx-community/Qwen3.6-27B-4bit"));
    try std.testing.expectEqualStrings("openai", maker("", "codex", "something"));
    try std.testing.expectEqualStrings("", maker("", "lmstudio", "lmstudio"));
    try std.testing.expect(of("anthropic") != null and of("nobody") == null);
}
