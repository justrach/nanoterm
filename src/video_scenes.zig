//! The video's frames, as one nanoui view: a title, nanoterm itself in a
//! window (a test fails, the agent says why, Vim's keys go inside the
//! output), the engine benchmark against Ghostty and Alacritty, what the
//! benchmark found, and the end. Every picture in it is drawn by nanoui.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const view = @import("view.zig");
const Workspace = @import("workspace.zig").Workspace;

pub const width = 1280;
pub const height = 720;

/// Where nanoterm's window sits.
pub const win = struct {
    pub const x = 110;
    pub const y = 96;
    pub const w = 1060;
    pub const h = 584;
};

/// When each scene starts, in seconds; the last ends the video.
pub const at = struct {
    pub const term = 3.0;
    pub const bench = 16.0;
    pub const fixes = 22.6;
    pub const end = 26.6;
    pub const done = 30.0;
};

/// Keys shown under the window as they are pressed: from, to, keys, what.
pub const Caption = struct { f32, f32, []const u8, []const u8 };

pub const Director = struct {
    w: *Workspace,
    /// The video's clock, set by the script.
    now: f32 = 0,
    captions: []const Caption = &.{},
    /// Dark around and in the window, else light.
    dark: bool = false,

    pub fn view(d: *Director, c: *ui.Context) void {
        const root = ui.div(c).sizeFull().bg(page());
        defer root.end();
        const t = d.now;
        if (t < at.term) {
            scene(c, t, 0, at.term, title, d);
        } else if (t < at.bench) {
            scene(c, t, at.term, at.bench, term, d);
        } else if (t < at.fixes) {
            scene(c, t, at.bench, at.fixes, bench, d);
        } else if (t < at.end) {
            scene(c, t, at.fixes, at.end, fixes, d);
        } else scene(c, t, at.end, at.done + 1, end, d);
    }
};

/// Around the window: a step deeper than the window's own background.
fn page() ui.Color {
    return theme.background.mix(if (theme.dark) ui.Color{} else theme.text, if (theme.dark) 0.35 else 0.05);
}

const Scene = fn (*ui.Context, *Director, f32) void;

/// A scene fading and rising in, and fading out at its end.
fn scene(c: *ui.Context, t: f32, start: f32, stop: f32, comptime draw: Scene, d: *Director) void {
    const in = ease(clamp01((t - start) / 0.45));
    const out = ease(clamp01((stop - t) / 0.35));
    const s = ui.div(c).absolute().sizeFull().opacity(in * out).offset(0, (1 - in) * 14);
    defer s.end();
    draw(c, d, t - start);
}

pub fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0, 1);
}

fn ease(v: f32) f32 {
    const u = 1 - v;
    return 1 - u * u * u;
}

fn part(t: f32, from: f32, len: f32) f32 {
    return ease(clamp01((t - from) / len));
}

fn title(c: *ui.Context, _: *Director, t: f32) void {
    const col = ui.div(c).column().sizeFull().center().gap(18);
    defer col.end();
    {
        const r = ui.div(c).row().gap(10).itemsCenter().opacity(part(t, 0.1, 0.5));
        defer r.end();
        const dot = ui.div(c).w(10).h(10).rounded(5).bg(theme.accent);
        dot.end();
        ui.text(c, "Built on nanoui", .{ .size = 18, .weight = .medium, .color = theme.muted });
    }
    {
        const n = ui.div(c).opacity(part(t, 0.25, 0.6)).offset(0, (1 - part(t, 0.25, 0.8)) * 20);
        defer n.end();
        ui.text(c, "nanoterm", .{ .size = 124, .weight = .bold, .color = theme.text });
    }
    typed(c, "A terminal for commands and coding agents.", t - 0.9, 38, .{ .size = 30, .color = theme.muted });
    const chips = [_][]const u8{ "One input for both", "Vim & Emacs keys", "A 2 MB app", "MIT" };
    const r = ui.div(c).row().gap(10).pt(16);
    defer r.end();
    for (chips, 0..) |s, i| {
        const f: f32 = @floatFromInt(i);
        const chip = ui.div(c).px(16).py(8).roundedFull().border(theme.border).bg(theme.background).opacity(part(t, 1.7 + f * 0.15, 0.4));
        defer chip.end();
        ui.text(c, s, .{ .size = 15, .weight = .medium, .color = theme.text });
    }
}

/// Text appearing a letter at a time, at `rate` letters a second.
fn typed(c: *ui.Context, s: []const u8, t: f32, rate: f32, style: ui.TextStyle) void {
    const n: usize = @intFromFloat(std.math.clamp(t * rate, 0, @as(f32, @floatFromInt(s.len))));
    const box = ui.div(c).row();
    defer box.end();
    ui.text(c, s[0..n], style);
    var hidden = style;
    hidden.color = .{ .a = 0 };
    ui.text(c, s[n..], hidden);
}

/// The window buttons, as macOS draws them.
fn lights(c: *ui.Context) void {
    const r = ui.div(c).row().gap(8);
    defer r.end();
    for ([_]u24{ 0xff5f57, 0xfebc2e, 0x28c840 }) |hex| {
        const l = ui.div(c).w(12).h(12).rounded(6).bg(.hex(hex));
        l.end();
    }
}

fn term(c: *ui.Context, d: *Director, t: f32) void {
    {
        const h = ui.div(c).absolute().wFull().column().itemsCenter().pt(22).gap(6);
        defer h.end();
        const r = ui.div(c).row().gap(10).itemsCenter();
        ui.text(c, "nanoterm", .{ .size = 24, .weight = .bold, .color = theme.text });
        ui.text(c, "commands and questions in one input", .{ .size = 20, .color = theme.muted });
        r.end();
        const lines = [_]struct { f32, []const u8 }{
            .{ 0, "Commands run as blocks you can fold, copy and rerun" },
            .{ 2.6, "Ask your agent, in the same input" },
            .{ 6.9, "Vim keys, even inside a command's output" },
        };
        var shown: usize = 0;
        for (lines, 0..) |l, i| if (t >= l[0]) {
            shown = i;
        };
        const since = t - lines[shown][0];
        const s = ui.div(c).opacity(part(since, 0, 0.4)).offset(0, (1 - part(since, 0, 0.4)) * 6);
        defer s.end();
        ui.text(c, lines[shown][1], .{ .size = 15, .color = theme.accent });
    }
    {
        const w = ui.div(c).absolute().offset(win.x, win.y).w(win.w).h(win.h).rounded(12).clip().bg(theme.background).border(.{ .a = if (d.dark) 0.5 else 0.12 }).shadow(.{ .color = .{ .a = if (d.dark) 0.5 else 0.18 }, .blur = 40, .y = 18 });
        defer w.end();
        // nanoterm lays itself out in the window it is given.
        const size = c.size;
        c.size = .{ .w = win.w, .h = win.h };
        view.view(d.w, c);
        c.size = size;
        const l = ui.div(c).absolute().offset(18, 18);
        defer l.end();
        lights(c);
    }
    caption(c, d);
}

/// The keys being pressed, under the window.
fn caption(c: *ui.Context, d: *Director) void {
    for (d.captions) |cap| {
        if (d.now < cap[0] or d.now > cap[1]) continue;
        const a = @min(clamp01((d.now - cap[0]) / 0.2), clamp01((cap[1] - d.now) / 0.2));
        const row = ui.div(c).absolute().wFull().offset(0, win.y + win.h - 70).row().justifyCenter().opacity(a);
        defer row.end();
        const pill = ui.div(c).row().gap(10).itemsCenter().px(16).py(10).roundedFull().bg(theme.solid.alpha(0.92)).shadow(.{ .color = .{ .a = 0.3 }, .blur = 18, .y = 6 });
        defer pill.end();
        var keys = std.mem.tokenizeScalar(u8, cap[2], ' ');
        while (keys.next()) |k| {
            const kb = ui.div(c).px(9).py(4).rounded(6).bg(theme.background.alpha(0.16)).border(theme.background.alpha(0.3));
            defer kb.end();
            ui.text(c, k, .{ .size = 15, .weight = .bold, .mono = true, .color = theme.background });
        }
        ui.text(c, cap[3], .{ .size = 15, .weight = .medium, .color = theme.background.alpha(0.85) });
    }
}

/// MB/s, median of 7 (bench/results/2026-10-19): nanoterm, Ghostty 1.3.1,
/// alacritty_terminal 0.26.0, the same 16 MiB streams on an Apple M3 Ultra.
const runs = [_]struct { []const u8, []const u8, [3]f32 }{
    .{ "full-screen", "a program redrawing, all three on a grid", .{ 315, 100, 209 } },
    .{ "logs", "lines of plain text", .{ 979, 151, 181 } },
    .{ "colors", "compiler and test output", .{ 281, 67, 159 } },
    .{ "unicode", "CJK, emoji, accents", .{ 1039, 70, 110 } },
    .{ "long lines", "wrapped many times", .{ 1848, 158, 210 } },
};

fn bench(c: *ui.Context, _: *Director, t: f32) void {
    const col = ui.div(c).column().sizeFull().px(120).py(44).gap(16).justifyCenter();
    defer col.end();
    {
        const h = ui.div(c).column().gap(8);
        defer h.end();
        ui.text(c, "Reads what programs print, fast", .{ .size = 38, .weight = .bold, .color = theme.text });
        ui.text(c, "MB/s through each terminal's engine, the same bytes, the same final screen. Higher is better.", .{ .size = 16, .color = theme.muted });
    }
    const colors = [3]ui.Color{ theme.accent, theme.agent.alpha(0.65), theme.faint };
    {
        const lg = ui.div(c).row().gap(18);
        defer lg.end();
        for ([_][]const u8{ "nanoterm", "Ghostty", "Alacritty" }, colors) |name, color| swatch(c, color, name);
    }
    const full: f32 = 560;
    for (runs, 0..) |run, i| {
        const f: f32 = @floatFromInt(i);
        const grow = part(t, 0.3 + f * 0.12, 0.8);
        const r = ui.div(c).row().gap(20).itemsCenter();
        defer r.end();
        {
            const name = ui.div(c).column().w(250).gap(1);
            defer name.end();
            ui.text(c, run[0], .{ .size = 16, .weight = .semibold, .color = theme.text });
            ui.text(c, run[1], .{ .size = 12, .color = theme.muted });
        }
        const max = @max(run[2][0], @max(run[2][1], run[2][2]));
        const bars = ui.div(c).column().gap(3);
        defer bars.end();
        for (run[2], colors, 0..) |v, color, j| bar(c, color, v, @max(3, full * v / max * grow), grow, j == 0);
    }
    const note = ui.div(c).pt(6).opacity(part(t, 1.8, 0.5));
    defer note.end();
    ui.text(c, "Engines only, no drawing. For output, nanoterm keeps styled lines and the others a cell grid; full-screen programs use a grid in all three.", .{ .size = 13, .color = theme.muted, .wrap = true });
}

fn swatch(c: *ui.Context, color: ui.Color, name: []const u8) void {
    const r = ui.div(c).row().gap(8).itemsCenter();
    defer r.end();
    const sw = ui.div(c).w(12).h(12).rounded(3).bg(color);
    sw.end();
    ui.text(c, name, .{ .size = 14, .weight = .medium, .color = theme.muted });
}

fn bar(c: *ui.Context, color: ui.Color, v: f32, w: f32, shown: f32, bold: bool) void {
    const r = ui.div(c).row().gap(10).itemsCenter();
    defer r.end();
    const b = ui.div(c).w(w).h(10).rounded(3).bg(color);
    b.end();
    const label = ui.div(c).opacity(shown);
    defer label.end();
    ui.text(c, c.print("{d:.0} MB/s", .{v * shown}), .{ .size = 11, .mono = true, .weight = if (bold) .bold else .regular, .color = if (bold) theme.text else theme.muted });
}

fn fixes(c: *ui.Context, _: *Director, t: f32) void {
    const col = ui.div(c).column().sizeFull().center().gap(28);
    defer col.end();
    {
        const h = ui.div(c).column().itemsCenter().gap(8);
        defer h.end();
        ui.text(c, "The benchmark paid for itself", .{ .size = 38, .weight = .bold, .color = theme.text });
        ui.text(c, "Its first runs found two slow paths in nanoterm. Both fixed, with tests.", .{ .size = 17, .color = theme.muted });
    }
    const items = [_]struct { []const u8, []const u8, f32, f32 }{
        .{ "Long output", "past 20,000 lines, old lines went one at a time", 4, 979 },
        .{ "Full-screen programs", "scrolling turns rows; plain text is written a row at a time", 72, 315 },
    };
    const r = ui.div(c).row().gap(28);
    defer r.end();
    for (items, 0..) |it, i| {
        const f: f32 = @floatFromInt(i);
        const p = part(t, 0.4 + f * 0.3, 0.9);
        const card = ui.div(c).column().w(420).gap(10).p(26).rounded(16).bg(theme.background).border(theme.border).opacity(part(t, 0.2 + f * 0.3, 0.4));
        defer card.end();
        ui.text(c, it[0], .{ .size = 20, .weight = .semibold, .color = theme.text });
        ui.text(c, it[1], .{ .size = 13, .color = theme.muted, .wrap = true });
        const nums = ui.div(c).row().gap(14).itemsCenter().pt(8);
        defer nums.end();
        ui.text(c, c.print("{d:.0}", .{it[2]}), .{ .size = 34, .weight = .medium, .mono = true, .color = theme.muted });
        ui.text(c, "→", .{ .size = 28, .color = theme.faint });
        ui.text(c, c.print("{d:.0}", .{it[2] + (it[3] - it[2]) * p}), .{ .size = 48, .weight = .bold, .mono = true, .color = theme.accent });
        ui.text(c, "MB/s", .{ .size = 16, .color = theme.muted });
    }
}

fn end(c: *ui.Context, _: *Director, t: f32) void {
    const col = ui.div(c).column().sizeFull().center().gap(18);
    defer col.end();
    ui.text(c, "nanoterm", .{ .size = 104, .weight = .bold, .color = theme.text });
    {
        const s = ui.div(c).opacity(part(t, 0.3, 0.5));
        defer s.end();
        ui.text(c, "Commands and coding agents, in one terminal.", .{ .size = 24, .color = theme.muted });
    }
    {
        const link = ui.div(c).row().gap(10).itemsCenter().px(22).py(12).roundedFull().bg(theme.accent).opacity(part(t, 0.7, 0.5));
        defer link.end();
        ui.text(c, "github.com/justrach/nanoterm", .{ .size = 20, .mono = true, .weight = .semibold, .color = theme.on_accent });
    }
    {
        const s = ui.div(c).column().itemsCenter().gap(6).pt(26).opacity(part(t, 1.2, 0.5));
        defer s.end();
        ui.text(c, "Built on nanoui. The benchmark is in bench/. MIT licensed.", .{ .size = 16, .color = theme.muted });
        ui.text(c, "Every frame of this video was drawn by nanoui.", .{ .size = 14, .color = theme.faint });
    }
}
