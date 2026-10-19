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
    @setEvalBranchQuota(2_000_000);
    const words =
        \\a about above add after again all also am an and any are around as ask at away back be because been before being below
        \\best better between big both bug bugs but by call can cannot change check clean code could create current day delete
        \\describe did different do does doing done down each easy else empty error errors even every everything example explain
        \\failing fails file files find first fix fixed for from function functions get give go going good got had has have
        \\having he help her here him his how i if implement improve in instead into is it its just keep kind know large last
        \\later latest least let like line lines list little look looks main make many may me might mine more most move much
        \\must my need new next no not now of off old on once one only open or other our out over own please port possible print
        \\problem process project quick quickly read readme really refactor remove rename repo repository right run running same
        \\say see set should show simple since slow small so some something start still stop such summarize sure take tell test
        \\tests than that the their them then there these they thing things think this those through time to today too try two
        \\under understand until up update us use used using very want was way we were what when where which while who why will
        \\with without work works would write wrong yes yet you your build builds compile compiles crash crashes deploy install
        \\installed folder folders directory directories biggest largest slowest newest oldest recent changes changed commit
        \\commits branch branches merge conflict conflicts why's what's how's it's don't doesn't isn't can't pass passing failed
        \\broken happen happened happening mean means reason documentation docs error's message messages output log logs
        \\anything nothing memory usage cpu disk space size names name type types value values variable variables able across
        \\actually added address afternoon against ago agree ahead allow almost alone along already although always among amount
        \\another answer anyone anyway anywhere apart appear apply approach april area argument arrange article august available
        \\avoid aware awful bad basically become becomes begin behind believe beside besides beyond bill book booking bottom
        \\bring brought business busy buy calendar called came care careful carry case cause certain chance chart cheap choose
        \\clear clearly close closer coffee come comes coming compare complete completely confirm consider contain contains
        \\contract copy correct cost costs count couple course cover dark data date dates dear decide default define depends
        \\design details difference difficult dinner doc document documents doesn email emails end ending english enough ensure
        \\entire especially evening ever exactly except excel expect expected expecting fact fair family far fast february feel
        \\few figure fill final finally fine finish five follow following four friday full fully further future gave general
        \\given glad great group guess half hand handle happy hard hate head hear held hello here's hi high hold home hope hour
        \\hours however huge idea ideas important include including income increase information inside interest issue issues
        \\it'll i'm i've january july june kept kid kids learn leave left less lets letter lease level life light likely limit
        \\link live long longer lose lost lot lots love low made mail mall manage march meaning meeting mention mentioned met
        \\middle mind minute minutes missing mistake moment monday money month months morning mostly near nearly necessary never
        \\nice night nobody none normal note notes number numbers obviously october often okay ones online order original
        \\otherwise outside page paid part particular people per percent perhaps person phone pick picture place plan plans
        \\point points pretty price prices private probably product properly property pull put question questions quite rather
        \\ready real reasons recently remaining remember rent reply report reports request require rest result results return
        \\review rule rules safe sales saturday save saw schedule second section seem seems sell send sense sent september seven
        \\several share sheet short shows side sign similar six sort sound sounds speak specific spend spreadsheet stand stay
        \\step steps story strange stuff sum summary sunday suppose system table talk team technically ten tenancy tenant
        \\tenants term terms text thanks three thursday together told tomorrow tonight top total towards true trying tuesday
        \\turn twice unless upon usually version wait walk wanted wants watch wednesday week weeks weird welcome well went
        \\whatever whole whose wide wish within wonder word words world worry worth wrote year years yesterday young
    ;
    var list: [count(words)]struct { []const u8 } = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, words, " \n");
    while (it.next()) |w| : (n += 1) list[n] = .{w};
    break :blk list;
});

fn count(comptime words: []const u8) usize {
    @setEvalBranchQuota(2_000_000);
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, words, " \n");
    while (it.next()) |_| n += 1;
    return n;
}

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
    for ([_][]const u8{ "s", "es", "ed", "ing", "ly", "er", "est", "d" }) |end| {
        if (w.len > end.len + 2 and std.mem.endsWith(u8, w, end) and english.has(w[0 .. w.len - end.len])) return true;
    }
    return false;
}

fn contains(list: []const []const u8, w: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, w)) return true;
    return false;
}

/// What joins commands: pipes, redirections, `&&`, `;`, substitutions.
fn operators(text: []const u8) bool {
    if (std.mem.indexOfAny(u8, text, "|><;`") != null) return true;
    return std.mem.indexOf(u8, text, "&&") != null or std.mem.indexOf(u8, text, "$(") != null;
}

fn flags(words: []const []const u8) bool {
    for (words) |w| if (w.len > 1 and w[0] == '-' and !std.ascii.isDigit(w[1])) return true;
    return false;
}

/// `NAME=value`: a variable set for the command after it.
fn assignment(w: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, w, '=') orelse return false;
    if (eq == 0) return false;
    for (w[0..eq]) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return std.ascii.isAlphabetic(w[0]) or w[0] == '_';
}

/// Characters that only shell commands use.
fn shellSyntax(text: []const u8) bool {
    if (std.mem.indexOfAny(u8, text, "|><;`$&=*\\{}[]") != null) return true;
    var words = std.mem.tokenizeAny(u8, text, " \t");
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
    const text = std.mem.trim(u8, text_in, " \t\r\n");
    if (text.len == 0) return .{ .kind = if (follow_up) .agent else .shell, .sure = true };
    // Several lines: a script when its first line surely is a command, else
    // a request (a prompt with a pasted error, a list).
    if (std.mem.indexOfScalar(u8, text, '\n')) |nl| {
        const head = guess(text[0..nl], commands, follow_up);
        if (head.kind == .shell and head.sure) return head;
        return .{ .kind = .agent, .sure = true };
    }
    var words: [64][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t");
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
    // A program by its path, or a variable set for one.
    if (first[0] == '/' or std.mem.startsWith(u8, first, "./") or std.mem.startsWith(u8, first, "../") or std.mem.startsWith(u8, first, "~/") or assignment(first))
        return .{ .kind = .shell, .sure = true };
    if (text[text.len - 1] == '?') return .{ .kind = .agent, .sure = true };
    const command = commands.has(first);
    if (n == 1) {
        if (contains(&one_off, first_lower)) return .{ .kind = .agent, .sure = true };
        // One word: a command, or a typo of one.
        return .{ .kind = .shell, .sure = command or !follow_up };
    }

    var english_words: usize = 0;
    for (words[0..n]) |w| english_words += @intFromBool(isEnglish(w));
    if (!command) {
        // Mostly English, whatever else it names (a path, a file, a & b):
        // a request.
        const ratio = @as(f32, @floatFromInt(english_words)) / @as(f32, @floatFromInt(n));
        const threshold: f32 = if (n <= 3) 1.0 else if (n <= 4) 0.75 else 0.6;
        if (ratio >= threshold) return .{ .kind = .agent, .sure = ratio >= 0.75 or n >= 6 };
        if (shellSyntax(text) and ratio < 0.4) return .{ .kind = .shell, .sure = true };
        if (ratio >= 0.4 or follow_up) return .{ .kind = .agent, .sure = false };
        return .{ .kind = .shell, .sure = false };
    }
    // A program, then pipes, redirections or flags: a command.
    if (operators(text) or flags(words[1..n])) return .{ .kind = .shell, .sure = true };
    const rest_english = english_words - @intFromBool(isEnglish(first));
    // "git status", "make test": a command and its arguments. After the
    // agent answered, two plain words ("go on", "do it") reply.
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

/// What a model may see of `text`: its words and its shape, with anything
/// that could be private put as a marker of its kind (paths, files, URLs,
/// emails, quoted text, values, numbers, long tokens), so that a command
/// still reads as one: `find . -name '*.zig' | wc -l` is
/// `find <path> -name <text> | wc -l`. Empty when nothing is left.
pub fn shape(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var quote: u8 = 0;
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (tokens.next()) |w| {
        // Quoted text, over as many words as it takes: one marker.
        if (quote != 0) {
            if (w[w.len - 1] == quote) quote = 0;
            continue;
        }
        var mark: []const u8 = w;
        var value: [64]u8 = undefined;
        if (w[0] == '\'' or w[0] == '"' or w[0] == '`') {
            if (w.len == 1 or w[w.len - 1] != w[0]) quote = w[0];
            mark = "<text>";
        } else mark = token(&value, w);
        if (n + mark.len + 1 > buf.len) break;
        if (n > 0) {
            buf[n] = ' ';
            n += 1;
        }
        @memcpy(buf[n .. n + mark.len], mark);
        n += mark.len;
    }
    return buf[0..n];
}

/// One word as `shape` shows it.
fn token(out: []u8, w: []const u8) []const u8 {
    const ops = [_][]const u8{ "|", "||", "&&", "&", ";", ">", ">>", "<", "2>", "2>&1", "&>" };
    if (contains(&ops, w)) return w;
    if (std.mem.indexOf(u8, w, "://") != null) return "<url>";
    if (std.mem.indexOfScalar(u8, w, '@') != null and std.mem.indexOfScalar(u8, w, '.') != null) return "<email>";
    if (w[0] == '-' and w.len > 1) {
        // A flag's name stays; its value doesn't.
        const eq = std.mem.indexOfScalar(u8, w, '=');
        const name = w[0 .. eq orelse w.len];
        if (name.len > 24 or !plain(std.mem.trimStart(u8, name, "-"))) return "<flag>";
        if (eq == null) return name;
        return std.fmt.bufPrint(out, "{s}=<value>", .{name}) catch "<flag>";
    }
    if (w[0] == '$') return if (w.len > 1 and w.len <= 24 and plain(w[1..])) w else "<var>";
    if (assignment(w)) return std.fmt.bufPrint(out, "{s}=<value>", .{w[0..std.mem.indexOfScalar(u8, w, '=').?]}) catch "<value>";
    if (std.mem.indexOfScalar(u8, w, '/') != null or w[0] == '~' or w[0] == '.') return "<path>";
    const bare = std.mem.trim(u8, w, ".,;:!?()");
    if (bare.len == 0) return w;
    var digits: usize = 0;
    for (bare) |ch| digits += @intFromBool(std.ascii.isDigit(ch));
    if (digits >= 4) return "<number>";
    if (bare.len > 24) return "<token>";
    // A name with an extension: a file.
    if (std.mem.lastIndexOfScalar(u8, bare, '.')) |dot| if (dot > 0 and dot + 1 < bare.len) return "<file>";
    if (std.mem.indexOfAny(u8, bare, "\\`@<>{}[]=$#:*") != null) return "<symbol>";
    return w;
}

/// Letters, digits, `-` and `_`: a flag's or variable's name.
fn plain(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

test "commands and requests" {
    var c: Commands = .init(std.testing.allocator);
    defer c.deinit();
    for ([_][]const u8{ "git", "ls", "find", "make", "kill", "cargo", "cat", "open", "echo", "docker", "wc", "cd", "npm", "mv" }) |w| c.add(w);
    const shell = [_][]const u8{
        "ls",                           "ls -la",                         "git status",              "git commit -m 'fix the bug'", "cat README.md",
        "make test",                    "cargo build --release",          "echo hello world",        "ls | grep zig",               "./run.sh",
        "kill 1234",                    "find . -name '*.zig' | wc -l",   "FOO=1 make test",         "docker run -it ubuntu bash",  "git log --oneline | head",
        "npm install",                  "/usr/bin/env python3 script.py", "cd src\nmake test",       "mv a.txt b.txt",              "unknowntool --flag value",
    };
    for (shell) |s| {
        const g = guess(s, &c, false);
        if (g.kind != .shell) std.debug.print("expected shell: {s}\n", .{s});
        try std.testing.expectEqual(Kind.shell, g.kind);
    }
    const agent = [_][]const u8{
        "why is the build failing",                         "find the biggest files in this repo",          "explain",
        "what does this project do?",                       "make the tests pass",                          "fix the failing tests please",
        "how do I undo my last commit",                     "/model",                                       "why does ./run.sh fail",
        "fix the error in src/main.zig",                    "move these two from downloads to this folder", "explain what src/jev.zig does",
        "the lease is expecting five years so the remaining two years technically like",
        "fix this:\nTypeError: cannot read [object] of undefined", "tom & jerry is the cartoon i mean",
    };
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

/// The first word of `text`, for what Jev is told about it.
pub fn firstWord(text: []const u8) []const u8 {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    return it.next() orelse "";
}

test "Jev sees a command's shape, never what's private in it" {
    var buf: [280]u8 = undefined;
    try std.testing.expectEqualStrings("find <path> -name <text> | wc -l", shape(&buf, "find . -name '*.zig' | wc -l"));
    try std.testing.expectEqualStrings("curl -H <text> <url>", shape(&buf, "curl -H 'Authorization: Bearer sk_live_123' https://x.io/y"));
    try std.testing.expectEqualStrings("TOKEN=<value> make deploy --env=<value> to <path>", shape(&buf, "TOKEN=abc123 make deploy --env=prod to ~/src"));
    try std.testing.expectEqualStrings("why does <path> fail on <file> for <email> after <number>", shape(&buf, "why does ./run.sh fail on main.zig for me@x.io after 123456"));
    try std.testing.expectEqualStrings("echo $HOME <text> <var>", shape(&buf, "echo $HOME \"a b c\" $(whoami)"));
}
