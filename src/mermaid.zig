//! Mermaid diagrams, parsed: flowcharts (`graph`/`flowchart`, any
//! direction, the usual shapes and edges with labels), state diagrams
//! (`stateDiagram`, `[*]` for start and end) and sequence diagrams
//! (participants, messages, notes, loops). `view_mermaid.zig` lays them
//! out and draws them; other kinds are named, to show their source.
const std = @import("std");

pub const Dir = enum { down, up, right, left };

pub const Shape = enum { rect, round, stadium, circle, diamond, hexagon, cylinder, subroutine, flag, start, end };

pub const Node = struct { id: []const u8, label: []const u8, shape: Shape = .rect };

pub const Line = enum { solid, dotted, thick, invisible };

pub const Edge = struct {
    from: usize,
    to: usize,
    label: []const u8 = "",
    line: Line = .solid,
    /// An arrowhead at its end, and at its start (`<-->`).
    head: bool = true,
    tail: bool = false,
};

pub const Flow = struct {
    dir: Dir = .down,
    nodes: []const Node,
    edges: []const Edge,
};

pub const Actor = struct { id: []const u8, label: []const u8, person: bool = false };

pub const Step = union(enum) {
    message: struct { from: usize, to: usize, text: []const u8, dashed: bool, head: bool },
    /// A note beside one actor (`left`/`right`) or over a span of them.
    note: struct { from: usize, to: usize, side: enum { left, right, over }, text: []const u8 },
    /// `loop`, `alt`, `opt`, `else`…: a label across the diagram.
    section: []const u8,
};

pub const Seq = struct { actors: []const Actor, steps: []const Step };

pub const Diagram = union(enum) {
    flow: Flow,
    seq: Seq,
    /// A kind not drawn (pie, gantt, class…): its name.
    other: []const u8,
};

pub fn parse(arena: std.mem.Allocator, src: []const u8) Diagram {
    return parseOr(arena, src) catch .{ .other = "diagram" };
}

fn parseOr(arena: std.mem.Allocator, src: []const u8) !Diagram {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        var l = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.indexOf(u8, l, "%%")) |c| l = std.mem.trim(u8, l[0..c], " \t");
        if (l.len > 0) try lines.append(arena, l);
    }
    if (lines.items.len == 0) return .{ .other = "empty" };
    const head = lines.items[0];
    var words = std.mem.tokenizeAny(u8, head, " \t");
    const kind = words.next() orelse "";
    if (std.mem.eql(u8, kind, "graph") or std.mem.eql(u8, kind, "flowchart")) {
        var f: FlowParser = .{ .arena = arena };
        f.dir = dirOf(words.next() orelse "TD");
        for (lines.items[1..]) |l| {
            var parts = std.mem.splitScalar(u8, l, ';');
            while (parts.next()) |stmt| try f.statement(std.mem.trim(u8, stmt, " \t"));
        }
        return .{ .flow = .{ .dir = f.dir, .nodes = f.nodes.items, .edges = f.edges.items } };
    }
    if (std.mem.startsWith(u8, kind, "stateDiagram")) {
        var f: FlowParser = .{ .arena = arena };
        for (lines.items[1..]) |l| try f.state(l);
        return .{ .flow = .{ .dir = f.dir, .nodes = f.nodes.items, .edges = f.edges.items } };
    }
    if (std.mem.eql(u8, kind, "sequenceDiagram")) {
        var s: SeqParser = .{ .arena = arena };
        for (lines.items[1..]) |l| try s.line(l);
        return .{ .seq = .{ .actors = s.actors.items, .steps = s.steps.items } };
    }
    return .{ .other = kind };
}

fn dirOf(s: []const u8) Dir {
    if (std.mem.eql(u8, s, "LR")) return .right;
    if (std.mem.eql(u8, s, "RL")) return .left;
    if (std.mem.eql(u8, s, "BT")) return .up;
    return .down;
}

/// A label as written: quotes off, `<br>` a line break, entities kept.
fn label(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var t = std.mem.trim(u8, raw, " \t");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') t = t[1 .. t.len - 1];
    if (t.len >= 2 and t[0] == '`' and t[t.len - 1] == '`') t = t[1 .. t.len - 1];
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < t.len) {
        const rest = t[i..];
        if (std.ascii.startsWithIgnoreCase(rest, "<br>") or std.ascii.startsWithIgnoreCase(rest, "<br/>") or std.ascii.startsWithIgnoreCase(rest, "<br />")) {
            try out.append(arena, '\n');
            i += std.mem.indexOfScalar(u8, rest, '>').? + 1;
            continue;
        }
        if (std.mem.startsWith(u8, rest, "\\n")) {
            try out.append(arena, '\n');
            i += 2;
            continue;
        }
        try out.append(arena, t[i]);
        i += 1;
    }
    return out.items;
}

const FlowParser = struct {
    arena: std.mem.Allocator,
    dir: Dir = .down,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,

    fn node(f: *FlowParser, id: []const u8, text: ?[]const u8, shape: ?Shape) !usize {
        for (f.nodes.items, 0..) |*n, i| if (std.mem.eql(u8, n.id, id)) {
            if (text) |t| n.label = t;
            if (shape) |s| n.shape = s;
            return i;
        };
        try f.nodes.append(f.arena, .{ .id = id, .label = text orelse id, .shape = shape orelse .rect });
        return f.nodes.items.len - 1;
    }

    fn statement(f: *FlowParser, s: []const u8) !void {
        if (s.len == 0) return;
        const skip = [_][]const u8{ "classDef ", "class ", "style ", "linkStyle ", "click ", "subgraph", "end", "direction " };
        for (skip) |w| if (std.mem.startsWith(u8, s, w)) {
            if (std.mem.eql(u8, w, "direction ")) f.dir = dirOf(std.mem.trim(u8, s[w.len..], " "));
            return;
        };
        var i: usize = 0;
        var sources: std.ArrayList(usize) = .empty;
        try f.group(s, &i, &sources);
        while (true) {
            skipSpace(s, &i);
            const e = edgeAt(f.arena, s, &i) orelse break;
            skipSpace(s, &i);
            var targets: std.ArrayList(usize) = .empty;
            try f.group(s, &i, &targets);
            if (targets.items.len == 0) break;
            for (sources.items) |a| for (targets.items) |b| {
                var edge = e;
                edge.from = a;
                edge.to = b;
                try f.edges.append(f.arena, edge);
            };
            sources = targets;
        }
    }

    /// Nodes joined by `&`.
    fn group(f: *FlowParser, s: []const u8, i: *usize, out: *std.ArrayList(usize)) !void {
        while (true) {
            skipSpace(s, i);
            const n = try f.nodeAt(s, i) orelse return;
            try out.append(f.arena, n);
            skipSpace(s, i);
            if (i.* < s.len and s[i.*] == '&') i.* += 1 else return;
        }
    }

    fn nodeAt(f: *FlowParser, s: []const u8, i: *usize) !?usize {
        const start = i.*;
        while (i.* < s.len) : (i.* += 1) {
            const ch = s[i.*];
            if (std.mem.indexOfScalar(u8, " \t[({>&;|", ch) != null) break;
            // An edge starts: `-` or `=` or `.` doubled, or `~~`.
            if ((ch == '-' or ch == '=' or ch == '.' or ch == '~' or ch == '<') and i.* + 1 < s.len and std.mem.indexOfScalar(u8, "-=.~>", s[i.* + 1]) != null) break;
        }
        if (i.* == start) return null;
        const id = s[start..i.*];
        const opens = [_]struct { []const u8, []const u8, Shape }{
            .{ "([", "])", .stadium }, .{ "[[", "]]", .subroutine }, .{ "[(", ")]", .cylinder },
            .{ "((", "))", .circle },  .{ "{{", "}}", .hexagon },    .{ "[/", "/]", .rect },
            .{ "[\\", "\\]", .rect },  .{ "[", "]", .rect },         .{ "(", ")", .round },
            .{ "{", "}", .diamond },   .{ ">", "]", .flag },
        };
        for (opens) |o| if (std.mem.startsWith(u8, s[i.*..], o[0])) {
            const body = i.* + o[0].len;
            const close = closeOf(s, body, o[1]) orelse continue;
            i.* = close + o[1].len;
            // `:::name` styles it: not drawn.
            if (std.mem.startsWith(u8, s[i.*..], ":::")) while (i.* < s.len and s[i.*] != ' ') : (i.* += 1) {};
            return try f.node(id, try label(f.arena, s[body..close]), o[2]);
        };
        return try f.node(id, null, null);
    }

    /// A state diagram's line: `A --> B : label`, `[*] --> A`, `state "x" as A`.
    fn state(f: *FlowParser, l: []const u8) !void {
        if (std.mem.startsWith(u8, l, "direction ")) {
            f.dir = dirOf(std.mem.trim(u8, l["direction ".len..], " "));
            return;
        }
        if (std.mem.startsWith(u8, l, "state ")) {
            const rest = l["state ".len..];
            if (std.mem.indexOf(u8, rest, " as ")) |as| {
                const id = std.mem.trim(u8, rest[as + 4 ..], " {");
                _ = try f.node(id, try label(f.arena, rest[0..as]), .round);
            }
            return;
        }
        if (std.mem.eql(u8, l, "}") or std.mem.startsWith(u8, l, "note ") or std.mem.startsWith(u8, l, "end note")) return;
        const arrow = std.mem.indexOf(u8, l, "-->") orelse {
            // `A : description` names a state.
            if (std.mem.indexOfScalar(u8, l, ':')) |c| _ = try f.node(std.mem.trim(u8, l[0..c], " "), try label(f.arena, l[c + 1 ..]), .round);
            return;
        };
        var right = l[arrow + 3 ..];
        var text: []const u8 = "";
        if (std.mem.indexOfScalar(u8, right, ':')) |c| {
            text = try label(f.arena, right[c + 1 ..]);
            right = right[0..c];
        }
        const a = try f.stateNode(std.mem.trim(u8, l[0..arrow], " "), true);
        const b = try f.stateNode(std.mem.trim(u8, right, " "), false);
        try f.edges.append(f.arena, .{ .from = a, .to = b, .label = text });
    }

    fn stateNode(f: *FlowParser, id: []const u8, from: bool) !usize {
        if (std.mem.eql(u8, id, "[*]")) return f.node(if (from) "[*]start" else "[*]end", "", if (from) .start else .end);
        return f.node(id, null, .round);
    }
};

fn closeOf(s: []const u8, from: usize, close: []const u8) ?usize {
    // Past a quoted label, whatever it holds.
    var i = from;
    while (i < s.len and (s[i] == ' ')) i += 1;
    if (i < s.len and s[i] == '"') if (std.mem.indexOfScalarPos(u8, s, i + 1, '"')) |q| {
        i = q + 1;
    };
    return std.mem.indexOfPos(u8, s, i, close);
}

fn skipSpace(s: []const u8, i: *usize) void {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t')) i.* += 1;
}

/// The edge at `i.*`: `-->`, `---`, `-.->`, `==>`, `--x`, `<-->`, `~~~`,
/// with a label `-- text -->` or `-->|text|`.
fn edgeAt(arena: std.mem.Allocator, s: []const u8, i: *usize) ?Edge {
    const start = i.*;
    var j = start;
    while (j < s.len and std.mem.indexOfScalar(u8, "<-=.~", s[j]) != null) j += 1;
    if (j < s.len and s[j] == '>') j += 1;
    if (j < s.len and (s[j] == 'x' or s[j] == 'o') and (j + 1 >= s.len or s[j + 1] == ' ' or s[j + 1] == '|')) j += 1;
    var tok = s[start..j];
    if (tok.len < 2) return null;
    var e: Edge = .{ .from = 0, .to = 0 };
    // `-- text -->`: the label between two halves.
    if (std.mem.eql(u8, tok, "--") or std.mem.eql(u8, tok, "==") or std.mem.eql(u8, tok, "-.")) {
        var k = j;
        while (k + 2 < s.len) : (k += 1) {
            if (s[k] == ' ' and std.mem.indexOfScalar(u8, "-=.", s[k + 1]) != null and std.mem.indexOfScalar(u8, "-=.>", s[k + 2]) != null) break;
        } else return null;
        e.label = label(arena, s[j..k]) catch "";
        var m = k + 1;
        while (m < s.len and std.mem.indexOfScalar(u8, "-=.", s[m]) != null) m += 1;
        if (m < s.len and (s[m] == '>' or s[m] == 'x' or s[m] == 'o')) m += 1;
        tok = s[start..m];
        j = m;
    }
    if (std.mem.indexOfScalar(u8, tok, '~') != null) e.line = .invisible else if (std.mem.indexOfScalar(u8, tok, '.') != null) e.line = .dotted else if (std.mem.indexOfScalar(u8, tok, '=') != null) e.line = .thick;
    const last = tok[tok.len - 1];
    e.head = last == '>' or last == 'x' or last == 'o';
    e.tail = tok[0] == '<';
    i.* = j;
    skipSpace(s, i);
    if (i.* < s.len and s[i.*] == '|') if (std.mem.indexOfScalarPos(u8, s, i.* + 1, '|')) |close| {
        e.label = label(arena, s[i.* + 1 .. close]) catch "";
        i.* = close + 1;
    };
    return e;
}

const SeqParser = struct {
    arena: std.mem.Allocator,
    actors: std.ArrayList(Actor) = .empty,
    steps: std.ArrayList(Step) = .empty,

    fn actor(s: *SeqParser, id: []const u8) !usize {
        for (s.actors.items, 0..) |a, i| if (std.mem.eql(u8, a.id, id)) return i;
        try s.actors.append(s.arena, .{ .id = id, .label = id });
        return s.actors.items.len - 1;
    }

    fn line(s: *SeqParser, l: []const u8) !void {
        for ([_][]const u8{ "participant ", "actor " }) |w| if (std.mem.startsWith(u8, l, w)) {
            const rest = std.mem.trim(u8, l[w.len..], " ");
            const as = std.mem.indexOf(u8, rest, " as ");
            const id = if (as) |a| rest[0..a] else rest;
            const i = try s.actor(id);
            if (as) |a| s.actors.items[i].label = try label(s.arena, rest[a + 4 ..]);
            s.actors.items[i].person = w[0] == 'a';
            return;
        };
        if (std.ascii.startsWithIgnoreCase(l, "note ")) return s.note(l["note ".len..]);
        const sections = [_][]const u8{ "loop", "alt", "else", "opt", "par", "and", "critical", "break", "option" };
        for (sections) |w| if (std.mem.startsWith(u8, l, w) and (l.len == w.len or l[w.len] == ' ')) {
            try s.steps.append(s.arena, .{ .section = try label(s.arena, l) });
            return;
        };
        const colon = std.mem.indexOfScalar(u8, l, ':') orelse return;
        const head = l[0..colon];
        // The longest arrow that fits: `-->>` before `->>` before `->`.
        const arrows = [_]struct { []const u8, bool, bool }{
            .{ "-->>", true, true }, .{ "->>", false, true }, .{ "--x", true, true }, .{ "-x", false, true },
            .{ "--)", true, true },  .{ "-)", false, true },  .{ "-->", true, false }, .{ "->", false, false },
        };
        for (arrows) |a| if (std.mem.indexOf(u8, head, a[0])) |at| {
            const from = std.mem.trim(u8, head[0..at], " ");
            const to = std.mem.trim(u8, head[at + a[0].len ..], " +-");
            if (from.len == 0 or to.len == 0) return;
            const fi = try s.actor(from);
            const ti = try s.actor(to);
            try s.steps.append(s.arena, .{ .message = .{ .from = fi, .to = ti, .text = try label(s.arena, l[colon + 1 ..]), .dashed = a[1], .head = a[2] } });
            return;
        };
    }

    fn note(s: *SeqParser, rest_in: []const u8) !void {
        const colon = std.mem.indexOfScalar(u8, rest_in, ':') orelse return;
        const where = std.mem.trim(u8, rest_in[0..colon], " ");
        const text = try label(s.arena, rest_in[colon + 1 ..]);
        const Side = @FieldType(@FieldType(Step, "note"), "side");
        var side: Side = .over;
        var who = where;
        for ([_]struct { []const u8, Side }{ .{ "left of ", .left }, .{ "right of ", .right }, .{ "over ", .over } }) |w| if (std.ascii.startsWithIgnoreCase(where, w[0])) {
            side = w[1];
            who = where[w[0].len..];
        };
        var names = std.mem.splitScalar(u8, who, ',');
        const a = try s.actor(std.mem.trim(u8, names.next() orelse return, " "));
        const b = if (names.next()) |n| try s.actor(std.mem.trim(u8, n, " ")) else a;
        try s.steps.append(s.arena, .{ .note = .{ .from = @min(a, b), .to = @max(a, b), .side = side, .text = text } });
    }
};

test "flowcharts: shapes, chains, labels, directions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const d = parse(arena.allocator(),
        \\graph LR
        \\  A[Start] --> B{Is it?}
        \\  B -->|Yes| C(Do it) --> D([Done])
        \\  B -- No --> E((Stop))
        \\  C -.-> A; D ==> F[["Sub<br>routine"]]
        \\  G & H --> I
        \\  classDef big fill:#f9f
    );
    const f = d.flow;
    try std.testing.expectEqual(Dir.right, f.dir);
    try std.testing.expectEqual(@as(usize, 9), f.nodes.len);
    try std.testing.expectEqual(Shape.diamond, f.nodes[1].shape);
    try std.testing.expectEqualStrings("Is it?", f.nodes[1].label);
    try std.testing.expectEqual(Shape.stadium, f.nodes[3].shape);
    try std.testing.expectEqual(Shape.circle, f.nodes[4].shape);
    try std.testing.expectEqualStrings("Sub\nroutine", f.nodes[5].label);
    try std.testing.expectEqual(@as(usize, 8), f.edges.len);
    try std.testing.expectEqualStrings("Yes", f.edges[1].label);
    try std.testing.expectEqualStrings("No", f.edges[3].label);
    try std.testing.expectEqual(Line.dotted, f.edges[4].line);
    try std.testing.expectEqual(Line.thick, f.edges[5].line);
    try std.testing.expectEqual(f.edges[6].to, f.edges[7].to);
}

test "state and sequence diagrams" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const st = parse(arena.allocator(),
        \\stateDiagram-v2
        \\  [*] --> Idle
        \\  Idle --> Busy : start
        \\  Busy --> [*]
    ).flow;
    try std.testing.expectEqual(@as(usize, 4), st.nodes.len);
    try std.testing.expectEqual(Shape.start, st.nodes[0].shape);
    try std.testing.expectEqualStrings("start", st.edges[1].label);
    const sq = parse(arena.allocator(),
        \\sequenceDiagram
        \\  participant U as User
        \\  actor A
        \\  U->>A: Hello
        \\  A-->>U: Hi back
        \\  loop Every minute
        \\  Note over U,A: a note
        \\  end
    ).seq;
    try std.testing.expectEqual(@as(usize, 2), sq.actors.len);
    try std.testing.expectEqualStrings("User", sq.actors[0].label);
    try std.testing.expect(sq.actors[1].person);
    try std.testing.expectEqual(@as(usize, 4), sq.steps.len);
    try std.testing.expect(sq.steps[1].message.dashed);
    try std.testing.expectEqualStrings("loop Every minute", sq.steps[2].section);
    try std.testing.expectEqual(@as(usize, 1), sq.steps[3].note.to);
    try std.testing.expectEqualStrings("pie", parse(arena.allocator(), "pie title Pets\n\"Dogs\" : 3").other);
}
