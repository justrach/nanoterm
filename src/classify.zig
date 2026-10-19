//! What the input is: a command for the shell, or a request for the agent.
//! Warp's way: rules first (a known command with flags or pipes is shell,
//! a sentence of English words is a request), and when the rules are not
//! sure, a model decides (Warp runs a small BERT locally; nanoterm asks
//! Codegraff's Jev, `jev.zig`). The rules are instant and stay local.
const std = @import("std");
const Commands = @import("commands.zig").Commands;

pub const Kind = enum { shell, agent };

pub const Guess = struct {
    kind: Kind,
    /// The rules are sure; otherwise a model may decide.
    sure: bool,
};

/// Words that alone are a request (Warp's one-off natural language words).
const one_off = [_][]const u8{ "hello", "hi", "hey", "thanks", "thank", "explain", "why", "what", "how", "help", "continue", "yes", "no", "ok", "okay", "please" };

/// Programs whose arguments are free text: always shell (Warp's list).
const shell_first = [_][]const u8{ "echo", "man", "sudo", "claude", "codex", "gemini", "graff", "printf", "export", "alias" };

/// Common English words: requests are mostly made of them.
const english = std.StaticStringMap(void).initComptime(blk: {
    @setEvalBranchQuota(20_000_000);
    const words =
        \\a about above add after again all also am an and any are around as ask at away back be because been before
        \\being below best better between big both bug bugs but by call can cannot change check clean code could create
        \\current day delete describe did different do does doing done down each easy else empty error errors even every
        \\everything example explain failing fails file files find first fix fixed for from function functions get give go
        \\going good got had has have having he help her here him his how i if implement improve in instead into is it
        \\its just keep kind know large last later latest least let like line lines list little look looks main make many
        \\may me might mine more most move much must my need new next no not now of off old on once one only open or
        \\other our out over own please port possible print problem process project quick quickly read readme really
        \\refactor remove rename repo repository right run running same say see set should show simple since slow small
        \\so some something start still stop such summarize sure take tell test tests than that the their them then there
        \\these they thing things think this those through time to today too try two under understand until up update
        \\us use used using very want was way we were what when where which while who why will with without work works
        \\would write wrong yes yet you your build builds compile compiles crash crashes deploy install installed
        \\folder folders directory directories biggest largest slowest newest oldest recent changes changed commit
        \\commits branch branches merge conflict conflicts why's what's how's it's don't doesn't isn't can't
        \\pass passing failed broken happen happened happening going mean means wrong reason documentation docs
        \\error's message messages output log logs please could would anything everything nothing all every each
        \\memory usage cpu disk space size big biggest names name type types value values variable variables
    ;
    var list: [600]struct { []const u8 } = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, words, " \n");
    var seen: []const []const u8 = &.{};
    while (it.next()) |w| {
        var dup = false;
        for (seen) |s| if (std.mem.eql(u8, s, w)) {
            dup = true;
        };
        if (dup) continue;
        seen = seen ++ .{w};
        list[n] = .{w};
        n += 1;
    }
    break :blk list[0..n].*;
});

fn lower(buf: []u8, w: []const u8) []const u8 {
    const n = @min(buf.len, w.len);
    for (w[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}

/// Whether `w` is a common English word, or one with a plain ending.
pub fn isEnglish(raw: []const u8) bool {
    var buf: [32]u8 = undefined;
    const trimmed = std.mem.trim(u8, raw, ".,;:!?\"()");
    if (trimmed.len == 0 or trimmed.len > buf.len) return false;
    const w = lower(&buf, trimmed);
    if (english.has(w)) return true;
    for ([_][]const u8{ "s", "es", "ed", "ing", "ly" }) |end| {
        if (w.len > end.len + 2 and std.mem.endsWith(u8, w, end) and english.has(w[0 .. w.len - end.len])) return true;
    }
    return false;
}

fn contains(list: []const []const u8, w: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, w)) return true;
    return false;
}

/// Characters that only shell commands use.
fn shellSyntax(text: []const u8) bool {
    if (std.mem.indexOfAny(u8, text, "|><;`$&=*\\{}[]") != null) return true;
    var words = std.mem.tokenizeScalar(u8, text, ' ');
    while (words.next()) |w| {
        if (w.len > 1 and w[0] == '-') return true; // flags
        if (std.mem.startsWith(u8, w, "./") or std.mem.startsWith(u8, w, "~/") or std.mem.startsWith(u8, w, "../")) return true;
        if (std.mem.indexOfScalar(u8, w, '/') != null and std.mem.indexOfScalar(u8, w, ' ') == null and w.len > 1 and w[0] != '/') return true;
    }
    return false;
}

/// What follows a command word only in a reply: "go on", "do it", "run
/// that again"; never a command's argument.
const reply_words = [_][]const u8{ "on", "ahead", "it", "that", "this", "them", "again", "me", "more", "please" };

/// Guesses what `text` is. `follow_up`: the agent answered last, so a
/// reply is likelier (Warp keeps follow-ups with the agent).
pub fn guess(text_in: []const u8, commands: *const Commands, follow_up: bool) Guess {
    const text = std.mem.trim(u8, text_in, " \t");
    if (text.len == 0) return .{ .kind = if (follow_up) .agent else .shell, .sure = true };
    var words: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, ' ');
    while (it.next()) |w| {
        if (n == words.len) break;
        words[n] = w;
        n += 1;
    }
    const first = words[0];
    var buf: [32]u8 = undefined;
    const first_lower = lower(&buf, std.mem.trim(u8, first, ".,!?"));

    // A slash command for the agent: "/model", not "/usr/bin/env".
    if (first[0] == '/' and std.mem.indexOfScalar(u8, first[1..], '/') == null) return .{ .kind = .agent, .sure = true };
    if (contains(&shell_first, first)) return .{ .kind = .shell, .sure = true };
    if (text[text.len - 1] == '?') return .{ .kind = .agent, .sure = true };
    const command = commands.has(first);
    if (n == 1) {
        if (contains(&one_off, first_lower)) return .{ .kind = .agent, .sure = true };
        // One word: a command, or a typo of one.
        return .{ .kind = .shell, .sure = command or !follow_up };
    }
    if (shellSyntax(text)) return .{ .kind = .shell, .sure = true };

    var english_words: usize = 0;
    for (words[0..n]) |w| english_words += @intFromBool(isEnglish(w));
    const rest_english = english_words - @intFromBool(isEnglish(first));
    if (command) {
        // "git status", "make test": a command and its arguments. After
        // the agent answered, two plain words ("go on", "do it") reply.
        if (n <= 2) {
            var b2: [32]u8 = undefined;
            if (follow_up and contains(&reply_words, lower(&b2, std.mem.trim(u8, words[1], ".,!")))) return .{ .kind = .agent, .sure = true };
            return .{ .kind = .shell, .sure = !isEnglish(words[1]) or !follow_up };
        }
        // "find the biggest files here": a command word opening a sentence.
        const ratio = @as(f32, @floatFromInt(rest_english)) / @as(f32, @floatFromInt(n - 1));
        if (ratio >= 0.75 and n >= 4) return .{ .kind = .agent, .sure = ratio >= 0.9 };
        if (ratio >= 0.5) return .{ .kind = if (follow_up) .agent else .shell, .sure = false };
        return .{ .kind = .shell, .sure = true };
    }
    const ratio = @as(f32, @floatFromInt(english_words)) / @as(f32, @floatFromInt(n));
    const threshold: f32 = if (n <= 3) 1.0 else if (n <= 4) 0.75 else 0.6;
    if (ratio >= threshold) return .{ .kind = .agent, .sure = ratio >= 0.8 or n >= 6 };
    if (ratio >= 0.4 or follow_up) return .{ .kind = .agent, .sure = false };
    return .{ .kind = .shell, .sure = false };
}

/// What a model may see of `text`: its words without paths, code, flags'
/// values, URLs, emails, ids, long tokens or anything secret-shaped — as
/// graff's Jev summaries are made. Empty when nothing safe is left.
pub fn redact(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var words = std.mem.tokenizeAny(u8, text, " \t\n");
    while (words.next()) |w| {
        if (w.len > 24) continue;
        if (std.mem.indexOfAny(u8, w, "/\\`@<>{}[]=$|_#~:") != null) continue;
        var digits: usize = 0;
        for (w) |ch| digits += @intFromBool(std.ascii.isDigit(ch));
        if (digits >= 4) continue;
        if (n + w.len + 1 > buf.len) break;
        if (n > 0) {
            buf[n] = ' ';
            n += 1;
        }
        @memcpy(buf[n .. n + w.len], w);
        n += w.len;
    }
    return buf[0..n];
}

test "commands and requests" {
    var c: Commands = .init(std.testing.allocator);
    defer c.deinit();
    for ([_][]const u8{ "git", "ls", "find", "make", "kill", "cargo", "cat", "open", "echo" }) |w| c.add(w);
    const shell = [_][]const u8{ "ls", "ls -la", "git status", "git commit -m 'fix the bug'", "cat README.md", "make test", "cargo build --release", "echo hello world", "ls | grep zig", "./run.sh", "kill 1234" };
    for (shell) |s| {
        const g = guess(s, &c, false);
        if (g.kind != .shell) std.debug.print("expected shell: {s}\n", .{s});
        try std.testing.expectEqual(Kind.shell, g.kind);
    }
    const agent = [_][]const u8{ "why is the build failing", "find the biggest files in this repo", "explain", "what does this project do?", "make the tests pass", "fix the failing tests please", "how do I undo my last commit", "/model" };
    for (agent) |s| {
        const g = guess(s, &c, false);
        if (g.kind != .agent) std.debug.print("expected agent: {s}\n", .{s});
        try std.testing.expectEqual(Kind.agent, g.kind);
    }
    try std.testing.expect(guess("git status", &c, false).sure);
    // Replies to the agent: a command word and a plain one.
    c.add("go");
    try std.testing.expectEqual(Kind.agent, guess("go on", &c, true).kind);
    try std.testing.expectEqual(Kind.shell, guess("go on", &c, false).kind);
    try std.testing.expectEqual(Kind.shell, guess("git status", &c, true).kind);
    try std.testing.expectEqual(Kind.shell, guess("go build", &c, true).kind);
    try std.testing.expectEqual(Kind.shell, guess("make test", &c, true).kind);
    try std.testing.expectEqual(Kind.agent, guess("open it", &c, true).kind);
    try std.testing.expect(isEnglish("Files"));
    try std.testing.expect(isEnglish("failing"));
    try std.testing.expect(!isEnglish("zig"));
}

test "redaction keeps words, drops what could be secret" {
    var buf: [280]u8 = undefined;
    const out = redact(&buf, "deploy with TOKEN=abc123 to https://x.io/y from ~/src and ask me@x.io about build_42 run 123456");
    try std.testing.expectEqualStrings("deploy with to from and ask about run", out);
}
