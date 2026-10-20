//! Starting an agent: the command line of each, as Harness starts them.
const std = @import("std");
const agent_mod = @import("agent.zig");
const proc = @import("proc.zig");
const agents = @import("agents.zig");
const graff_update = @import("graff_update.zig");

/// Whether `which`'s CLI is installed (on PATH or where installers put it).
pub fn installed(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, which: agent_mod.Which) bool {
    const path = agents.searchPath(arena, env.get("PATH") orelse "", env.get("HOME") orelse "/");
    if (which == .graff) return graff(arena, io, env, path) != null;
    return proc.which(arena, io, path, agents.info(which).cli) != null;
}

/// How to start each agent in ACP mode, as Harness does: `graff acp`,
/// Claude Code and Codex through their ACP adapters, the others' own ACP
/// commands. Agents are looked for on PATH and where installers put them.
pub fn argv(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, which: agent_mod.Which, model: ?[]const u8) ![*:null]const ?[*:0]const u8 {
    const path = agents.searchPath(arena, env.get("PATH") orelse "", env.get("HOME") orelse "/");
    switch (which) {
        .codex => {
            if (proc.which(arena, io, path, "codex-acp")) |bin| return proc.cStrings(arena, &.{bin});
            if (proc.which(arena, io, path, "codex") == null) return error.NotInstalled;
            const npx = proc.which(arena, io, path, "npx") orelse return error.NotInstalled;
            return proc.cStrings(arena, &.{ npx, "-y", "@agentclientprotocol/codex-acp@1.1.14" });
        },
        .opencode => return proc.cStrings(arena, &.{ proc.which(arena, io, path, "opencode") orelse return error.NotInstalled, "acp" }),
        .grok => return proc.cStrings(arena, &.{ proc.which(arena, io, path, "grok") orelse return error.NotInstalled, "--no-auto-update", "agent", "--no-leader", "stdio" }),
        .devin => return proc.cStrings(arena, &.{ proc.which(arena, io, path, "devin") orelse return error.NotInstalled, "acp" }),
        .hermes => return proc.cStrings(arena, &.{ proc.which(arena, io, path, "hermes") orelse return error.NotInstalled, "acp" }),
        .graff => {
            // A session starting is when Harness checks for a newer graff;
            // this one runs the graff found now.
            if (graff_update.global) |u| u.checkSoon();
            const bin = graff(arena, io, env, path) orelse return error.NotInstalled;
            if (model) |m| return proc.cStrings(arena, &.{ bin, "acp", "--yolo", "--model", m });
            return proc.cStrings(arena, &.{ bin, "acp", "--yolo" });
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

/// The graff to run, as Harness picks it: `GRAFF_EXECUTABLE`, else the
/// newest graff on PATH, where installers put it, or nanoterm's own copy.
fn graff(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, path: []const u8) ?[]const u8 {
    if (env.get("GRAFF_EXECUTABLE")) |own| if (own.len > 0) return own;
    const managed = graff_update.managedPath(arena, env.get("HOME") orelse "/") catch return null;
    return graff_update.resolve(arena, io, path, managed);
}
