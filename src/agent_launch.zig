//! Starting an agent: the command line of each, as Harness starts them.
const std = @import("std");
const agent_mod = @import("agent.zig");
const proc = @import("proc.zig");

/// How to start each agent in ACP mode, as Harness does: `graff acp`, and
/// Claude Code through its ACP adapter (Zed's install, else npx).
pub fn argv(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, which: agent_mod.Which, model: ?[]const u8) ![*:null]const ?[*:0]const u8 {
    const path = env.get("PATH") orelse "";
    switch (which) {
        .graff => {
            const graff = proc.which(arena, io, path, "graff") orelse return error.NotInstalled;
            if (model) |m| return proc.cStrings(arena, &.{ graff, "acp", "--yolo", "--model", m });
            return proc.cStrings(arena, &.{ graff, "acp", "--yolo" });
        },
        .claude => {
            if (proc.which(arena, io, path, "claude-agent-acp")) |bin| return proc.cStrings(arena, &.{bin});
            const node = proc.which(arena, io, path, "node") orelse return error.NotInstalled;
            const home = env.get("HOME") orelse "/";
            const base = try std.fs.path.join(arena, &.{ home, "Library/Application Support/Zed/external_agents/claude-agent-acp" });
            if (std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true })) |dir_| {
                var dir = dir_;
                defer dir.close(io);
                var it = dir.iterate();
                var newest: ?[]const u8 = null;
                while (it.next(io) catch null) |e| {
                    if (e.kind != .directory) continue;
                    if (newest == null or std.mem.order(u8, e.name, newest.?) == .gt) newest = try arena.dupe(u8, e.name);
                }
                if (newest) |v| {
                    const entry = try std.fs.path.join(arena, &.{ base, v, "node_modules/@zed-industries/claude-agent-acp/dist/index.js" });
                    if (std.Io.Dir.cwd().access(io, entry, .{})) |_| return proc.cStrings(arena, &.{ node, entry }) else |_| {}
                }
            } else |_| {}
            const npx = proc.which(arena, io, path, "npx") orelse return error.NotInstalled;
            return proc.cStrings(arena, &.{ npx, "-y", "@zed-industries/claude-agent-acp" });
        },
    }
}
