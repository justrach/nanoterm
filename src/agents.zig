//! The agents nanoterm can talk to, as Harness ships them: those that
//! speak ACP over stdio. For each: its name, the CLI that shows it is
//! installed, where installers put it, and the installer Harness runs
//! (from each vendor's documented one-liner).
const std = @import("std");
const Which = @import("agent.zig").Which;

pub const Info = struct {
    which: Which,
    /// The program that has to be installed (the agent's own CLI).
    cli: []const u8,
    blurb: []const u8,
    /// What installs it, run in a terminal block.
    install: []const u8,
    /// Where its sign-in is done, when it has its own.
    login: []const u8 = "",
};

pub const all = [_]Info{
    .{ .which = .graff, .cli = "graff", .blurb = "Codegraff's agent: any model, Codegraff's credits or your own keys", .install = "curl -fsSL https://github.com/justrach/codegraff/releases/latest/download/install.sh | sh", .login = "graff login" },
    .{ .which = .claude, .cli = "claude", .blurb = "Anthropic's Claude Code, through its ACP adapter", .install = "curl -fsSL https://claude.ai/install.sh | bash", .login = "claude /login" },
    .{ .which = .codex, .cli = "codex", .blurb = "OpenAI's Codex, through its ACP adapter", .install = "curl -fsSL https://chatgpt.com/codex/install.sh | sh", .login = "codex login" },
    .{ .which = .opencode, .cli = "opencode", .blurb = "SST's opencode", .install = "curl -fsSL https://opencode.ai/install | bash", .login = "opencode auth login" },
    .{ .which = .grok, .cli = "grok", .blurb = "xAI's Grok Build", .install = "curl -fsSL https://x.ai/cli/install.sh | bash" },
    .{ .which = .devin, .cli = "devin", .blurb = "Cognition's Devin", .install = "curl -fsSL https://cli.devin.ai/install.sh | bash" },
    .{ .which = .hermes, .cli = "hermes", .blurb = "Nous Research's Hermes Agent", .install = "curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash" },
};

pub fn info(which: Which) Info {
    for (all) |i| if (i.which == which) return i;
    unreachable;
}

/// Folders installers put agents in, besides PATH (`~/` is the home).
pub const extra_dirs = if (@import("builtin").os.tag == .windows)
    [_][]const u8{ "~/.local/bin", "~/AppData/Roaming/npm", "~/.bun/bin", "~/scoop/shims", "~/.cargo/bin" }
else
    [_][]const u8{ "~/.local/bin", "~/bin", "~/.harness/bin", "~/.opencode/bin", "~/.grok/bin", "~/.hermes/bin", "~/.claude/local", "~/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin" };

/// PATH with the installers' folders after it, in `arena`.
pub fn searchPath(arena: std.mem.Allocator, path: []const u8, home: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena, path) catch return path;
    for (extra_dirs) |d| {
        out.append(arena, std.fs.path.delimiter) catch return path;
        if (std.mem.startsWith(u8, d, "~/")) {
            out.appendSlice(arena, home) catch return path;
            out.appendSlice(arena, d[1..]) catch return path;
        } else out.appendSlice(arena, d) catch return path;
    }
    return out.items;
}

test "every agent is listed once, with its installer" {
    for (std.enums.values(Which)) |w| {
        var n: usize = 0;
        for (all) |i| if (i.which == w) {
            n += 1;
            try std.testing.expect(i.install.len > 0 and i.cli.len > 0);
        };
        try std.testing.expectEqual(@as(usize, 1), n);
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const p = searchPath(arena.allocator(), "/usr/bin", "/Users/me");
    try std.testing.expect(std.mem.startsWith(u8, p, "/usr/bin:/Users/me/.local/bin:"));
}
