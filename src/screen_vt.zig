//! The escape sequences full-screen programs drive a screen with, as
//! xterm takes them: cursor movement, erasing, scrolling regions,
//! inserting and deleting, SGR colors and attributes, modes, DEC line
//! drawing, and answers to what programs ask (the cursor's position, the
//! terminal's kind, its colors). Parsing stops where the program leaves
//! the alternate screen; the bytes after go back to the blocks.
const std = @import("std");
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;
const theme = @import("theme.zig");
const screen = @import("screen.zig");
const Screen = screen.Screen;

const State = enum { ground, esc, esc_charset, esc_hash, csi, osc, osc_esc, string, string_esc };

pub const Vt = struct {
    screen: *Screen,
    state: State = .ground,
    /// CSI: its prefix (`?`, `>`…), parameters and intermediate.
    prefix: u8 = 0,
    params: [96]u8 = undefined,
    params_len: usize = 0,
    inter: u8 = 0,
    /// Which set ESC ( or ESC ) chooses.
    charset_g1: bool = false,
    osc: std.ArrayList(u8) = .empty,
    /// A UTF-8 character split across reads.
    utf8: [4]u8 = undefined,
    utf8_len: u8 = 0,
    utf8_want: u8 = 0,
    /// The last character written, for REP.
    last: u21 = ' ',

    pub fn create(gpa: std.mem.Allocator, cols: u16, rows: u16) !*Vt {
        const v = try gpa.create(Vt);
        errdefer gpa.destroy(v);
        v.* = .{ .screen = try Screen.create(gpa, cols, rows) };
        return v;
    }

    pub fn destroy(v: *Vt) void {
        const gpa = v.screen.gpa;
        v.osc.deinit(gpa);
        v.screen.destroy();
        gpa.destroy(v);
    }

    fn reply(v: *Vt, bytes: []const u8) void {
        if (v.screen.reply) |r| r.func(r.ctx, bytes);
    }

    /// Feeds bytes until they end or the program leaves the screen; returns
    /// how many it took.
    pub fn feed(v: *Vt, bytes: []const u8) usize {
        const s = v.screen;
        var i: usize = 0;
        while (i < bytes.len) : (i += 1) {
            const b = bytes[i];
            switch (v.state) {
                .ground => {
                    if (v.utf8_want > 0) {
                        if (b & 0xc0 == 0x80) {
                            v.utf8[v.utf8_len] = b;
                            v.utf8_len += 1;
                            if (v.utf8_len == v.utf8_want) {
                                v.utf8_want = 0;
                                v.print(std.unicode.utf8Decode(v.utf8[0..v.utf8_len]) catch 0xfffd);
                            }
                            continue;
                        }
                        v.utf8_want = 0;
                        v.print(0xfffd);
                    }
                    switch (b) {
                        0x1b => v.state = .esc,
                        0x00...0x1a, 0x1c...0x1f => v.control(b),
                        0x7f => {},
                        0x20...0x7e => v.print(b),
                        else => {
                            const n = std.unicode.utf8ByteSequenceLength(b) catch {
                                v.print(0xfffd);
                                continue;
                            };
                            v.utf8[0] = b;
                            v.utf8_len = 1;
                            v.utf8_want = n;
                        },
                    }
                },
                .esc => v.escape(b),
                .esc_charset => {
                    const lines = b == '0';
                    if (v.charset_g1) s.g1_lines = lines else s.g0_lines = lines;
                    v.state = .ground;
                },
                .esc_hash => v.state = .ground,
                .csi => switch (b) {
                    0x30...0x3f => {
                        if (v.params_len == 0 and v.prefix == 0 and (b == '?' or b == '>' or b == '<' or b == '=')) {
                            v.prefix = b;
                        } else if (v.params_len < v.params.len) {
                            v.params[v.params_len] = b;
                            v.params_len += 1;
                        }
                    },
                    0x20...0x2f => v.inter = b,
                    0x40...0x7e => {
                        v.state = .ground;
                        v.csi(b);
                        if (s.done) return i + 1;
                    },
                    0x1b => v.state = .esc,
                    0x00...0x1a, 0x1c...0x1f => v.control(b),
                    else => v.state = .ground,
                },
                .osc => switch (b) {
                    0x07 => v.endOsc(),
                    0x1b => v.state = .osc_esc,
                    // Room for what a program copies (OSC 52, base64).
                    else => if (v.osc.items.len < 1 << 20) v.osc.append(s.gpa, b) catch {},
                },
                .osc_esc => v.endOsc(),
                // DCS, APC, PM and SOS: read to their end and dropped.
                .string => {
                    if (b == 0x1b) v.state = .string_esc else if (b == 0x07) v.state = .ground;
                },
                .string_esc => v.state = if (b == '\\') .ground else .string,
            }
        }
        return i;
    }

    fn print(v: *Vt, cp: u21) void {
        v.last = cp;
        v.screen.put(cp);
    }

    fn control(v: *Vt, b: u8) void {
        const s = v.screen;
        switch (b) {
            0x08 => {
                if (s.cur.x > 0) s.cur.x -= 1;
                s.pending_wrap = false;
            },
            0x09 => s.tab(),
            0x0a, 0x0b, 0x0c => s.lineFeed(),
            0x0d => {
                s.cur.x = 0;
                s.pending_wrap = false;
            },
            0x0e => s.shift_out = true,
            0x0f => s.shift_out = false,
            else => {},
        }
    }

    fn escape(v: *Vt, b: u8) void {
        const s = v.screen;
        v.state = .ground;
        switch (b) {
            '[' => {
                v.state = .csi;
                v.prefix = 0;
                v.params_len = 0;
                v.inter = 0;
            },
            ']' => {
                v.state = .osc;
                v.osc.clearRetainingCapacity();
            },
            'P', 'X', '^', '_' => v.state = .string,
            '(', ')' => {
                v.charset_g1 = b == ')';
                v.state = .esc_charset;
            },
            '*', '+' => v.state = .esc_charset,
            '#' => v.state = .esc_hash,
            '7' => s.save(),
            '8' => s.restore(),
            'D' => s.lineFeed(),
            'E' => {
                s.cur.x = 0;
                s.lineFeed();
            },
            'M' => s.reverseIndex(),
            'H' => s.tabs.set(s.cur.x),
            'c' => v.reset(),
            else => {},
        }
    }

    /// RIS: as it was made, at its size.
    fn reset(v: *Vt) void {
        const s = v.screen;
        s.cur = .{};
        s.saved = .{};
        s.top = 0;
        s.bottom = s.rows - 1;
        s.app_cursor = false;
        s.cursor_visible = true;
        s.autowrap = true;
        s.insert = false;
        s.g0_lines = false;
        s.g1_lines = false;
        s.shift_out = false;
        s.eraseDisplay(2);
    }

    fn param(v: *const Vt, index: usize, default: u32) u32 {
        var it = std.mem.splitScalar(u8, v.params[0..v.params_len], ';');
        var k: usize = 0;
        while (it.next()) |p| : (k += 1) {
            if (k != index) continue;
            const main = p[0 .. std.mem.indexOfScalar(u8, p, ':') orelse p.len];
            const n = std.fmt.parseInt(u32, main, 10) catch return default;
            return if (n == 0) default else n;
        }
        return default;
    }

    fn csi(v: *Vt, final: u8) void {
        const s = v.screen;
        if (v.prefix == '?') return v.privateMode(final);
        if (v.prefix == '>') {
            if (final == 'c') v.reply("\x1b[>1;10;0c");
            return;
        }
        if (v.prefix != 0 or (v.inter != 0 and final != 'q')) return;
        const n = v.param(0, 1);
        switch (final) {
            '@' => s.insertChars(n),
            'A' => s.moveBy(0, -@as(i32, @intCast(n))),
            'B', 'e' => s.moveBy(0, @intCast(n)),
            'C', 'a' => s.moveBy(@intCast(n), 0),
            'D' => s.moveBy(-@as(i32, @intCast(n)), 0),
            'E' => {
                s.moveBy(0, @intCast(n));
                s.cur.x = 0;
            },
            'F' => {
                s.moveBy(0, -@as(i32, @intCast(n)));
                s.cur.x = 0;
            },
            'G', '`' => {
                s.cur.x = @intCast(@min(n - 1, s.cols - 1));
                s.pending_wrap = false;
            },
            'H', 'f' => s.moveTo(v.param(1, 1) - 1, n - 1),
            'd' => {
                const x = s.cur.x;
                s.moveTo(x, n - 1);
            },
            'I' => for (0..n) |_| s.tab(),
            'J' => s.eraseDisplay(v.param(0, 0)),
            'K' => s.eraseLine(v.param(0, 0)),
            'L' => s.insertLines(n),
            'M' => s.deleteLines(n),
            'P' => s.deleteChars(n),
            'S' => s.scrollUp(n),
            'T' => s.scrollDown(n),
            'X' => s.eraseChars(n),
            'b' => for (0..@min(n, 4096)) |_| s.put(v.last),
            'g' => if (v.param(0, 0) == 3) s.tabs.unsetAll() else if (s.cur.x < s.cols) s.tabs.unset(s.cur.x),
            'h', 'l' => if (v.param(0, 0) == 4) {
                s.insert = final == 'h';
            },
            'm' => v.sgr(),
            'n' => switch (v.param(0, 0)) {
                5 => v.reply("\x1b[0n"),
                6 => {
                    var buf: [32]u8 = undefined;
                    const base: u16 = if (s.cur.origin) s.top else 0;
                    v.reply(std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ s.cur.y - base + 1, s.cur.x + 1 }) catch return);
                },
                else => {},
            },
            'c' => if (v.param(0, 0) == 0) v.reply("\x1b[?62;22c"),
            'r' => s.setRegion(v.param(0, 0), v.param(1, 0)),
            's' => if (v.params_len == 0) s.save(),
            'u' => if (v.params_len == 0) s.restore(),
            else => {},
        }
    }

    fn privateMode(v: *Vt, final: u8) void {
        const s = v.screen;
        if (final != 'h' and final != 'l') return;
        const on = final == 'h';
        var it = std.mem.splitScalar(u8, v.params[0..v.params_len], ';');
        while (it.next()) |p| {
            const mode = std.fmt.parseInt(u32, p, 10) catch continue;
            switch (mode) {
                1 => s.app_cursor = on,
                6 => {
                    s.cur.origin = on;
                    s.moveTo(0, 0);
                },
                7 => s.autowrap = on,
                25 => s.cursor_visible = on,
                1048 => if (on) s.save() else s.restore(),
                2004 => s.bracketed_paste = on,
                9, 1000 => s.mouse = if (on) .press else .off,
                1002 => s.mouse = if (on) .drag else .off,
                1003 => s.mouse = if (on) .motion else .off,
                1006 => s.mouse_sgr = on,
                // Leaving the alternate screen ends this screen.
                47, 1047, 1049 => if (!on) {
                    s.done = true;
                    return;
                },
                else => {},
            }
        }
    }

    fn sgr(v: *Vt) void {
        const pen = &v.screen.cur.pen;
        if (v.params_len == 0) {
            pen.* = .{};
            return;
        }
        var groups: [32][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, v.params[0..v.params_len], ';');
        while (it.next()) |g| {
            if (n == groups.len) break;
            groups[n] = g;
            n += 1;
        }
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const g = groups[k];
            // Colon forms: 38:2::r:g:b, 38:5:n, 4:3 (curly underline).
            if (std.mem.indexOfScalar(u8, g, ':') != null) {
                v.sgrColon(g);
                continue;
            }
            const code = if (g.len == 0) 0 else std.fmt.parseInt(u32, g, 10) catch continue;
            switch (code) {
                0 => pen.* = .{},
                1 => pen.attrs.bold = true,
                2 => pen.attrs.dim = true,
                3 => pen.attrs.italic = true,
                4, 21 => pen.attrs.underline = true,
                7 => pen.attrs.inverse = true,
                9 => pen.attrs.strike = true,
                22 => {
                    pen.attrs.bold = false;
                    pen.attrs.dim = false;
                },
                23 => pen.attrs.italic = false,
                24 => pen.attrs.underline = false,
                27 => pen.attrs.inverse = false,
                29 => pen.attrs.strike = false,
                30...37 => pen.fg = theme.ansi[code - 30],
                39 => pen.fg = null,
                40...47 => pen.bg = theme.ansi[code - 40],
                49 => pen.bg = null,
                90...97 => pen.fg = theme.ansi[code - 90 + 8],
                100...107 => pen.bg = theme.ansi[code - 100 + 8],
                38, 48 => {
                    const target = if (code == 38) &pen.fg else &pen.bg;
                    const kind = if (k + 1 < n) std.fmt.parseInt(u32, groups[k + 1], 10) catch 0 else 0;
                    if (kind == 5 and k + 2 < n) {
                        target.* = theme.color256(@intCast(@min(std.fmt.parseInt(u32, groups[k + 2], 10) catch 0, 255)));
                        k += 2;
                    } else if (kind == 2 and k + 4 < n) {
                        target.* = rgb(groups[k + 2], groups[k + 3], groups[k + 4]);
                        k += 4;
                    }
                },
                else => {},
            }
        }
    }

    fn sgrColon(v: *Vt, g: []const u8) void {
        const pen = &v.screen.cur.pen;
        var parts: [6][]const u8 = @splat("");
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, g, ':');
        while (it.next()) |p| {
            if (n == parts.len) break;
            parts[n] = p;
            n += 1;
        }
        const code = std.fmt.parseInt(u32, parts[0], 10) catch return;
        if (code == 4) {
            pen.attrs.underline = !std.mem.eql(u8, parts[1], "0");
            return;
        }
        if (code != 38 and code != 48) return;
        const target = if (code == 38) &pen.fg else &pen.bg;
        if (std.mem.eql(u8, parts[1], "5")) {
            target.* = theme.color256(@intCast(@min(std.fmt.parseInt(u32, parts[2], 10) catch 0, 255)));
        } else if (std.mem.eql(u8, parts[1], "2")) {
            // With or without the color space: 38:2::r:g:b or 38:2:r:g:b.
            const at: usize = if (n >= 6) 3 else 2;
            target.* = rgb(parts[at], parts[at + 1], parts[at + 2]);
        }
    }

    fn rgb(r: []const u8, g: []const u8, b: []const u8) Color {
        const f = struct {
            fn c(s: []const u8) f32 {
                return @as(f32, @floatFromInt(@min(std.fmt.parseInt(u32, s, 10) catch 0, 255))) / 255;
            }
        }.c;
        return .{ .r = f(r), .g = f(g), .b = f(b) };
    }

    /// Titles, the colors programs ask for to choose light or dark, and
    /// what they copy (OSC 52: their own selection, over SSH too). What is
    /// on the clipboard is never told.
    fn endOsc(v: *Vt) void {
        v.state = .ground;
        const p = v.osc.items;
        const s = v.screen;
        if (std.mem.startsWith(u8, p, "0;") or std.mem.startsWith(u8, p, "2;")) {
            s.title.clearRetainingCapacity();
            s.title.appendSlice(s.gpa, p[2..]) catch {};
        } else if (std.mem.startsWith(u8, p, "52;")) {
            const semi = std.mem.indexOfScalarPos(u8, p, 3, ';') orelse return;
            const data = p[semi + 1 ..];
            if (std.mem.eql(u8, data, "?")) return;
            const D = std.base64.standard.Decoder;
            const out = s.gpa.alloc(u8, D.calcSizeForSlice(data) catch return) catch return;
            D.decode(out, data) catch {
                s.gpa.free(out);
                return;
            };
            if (s.copied) |old| s.gpa.free(old);
            s.copied = out;
        } else if (std.mem.eql(u8, p, "10;?") or std.mem.eql(u8, p, "11;?")) {
            const c = if (p[1] == '0') theme.text else theme.background;
            var buf: [64]u8 = undefined;
            const ch = struct {
                fn f(x: f32) u16 {
                    return @intFromFloat(@round(x * 65535));
                }
            }.f;
            v.reply(std.fmt.bufPrint(&buf, "\x1b]{s};rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{ p[0..2], ch(c.r), ch(c.g), ch(c.b) }) catch return);
        }
    }
};

test "a full-screen program's session" {
    // The dark palette, whatever an earlier test left.
    theme.apply(.dark);
    const gpa = std.testing.allocator;
    const v = try Vt.create(gpa, 10, 4);
    defer v.destroy();
    const Rec = struct {
        got: [64]u8 = undefined,
        n: usize = 0,
        fn on(ctx: *anyopaque, bytes: []const u8) void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(r.got[r.n..][0..bytes.len], bytes);
            r.n += bytes.len;
        }
    };
    var rec: Rec = .{};
    v.screen.reply = .{ .ctx = &rec, .func = Rec.on };
    const s = v.screen;
    // Clear, a bold red title at the top, a status line at the bottom.
    _ = v.feed("\x1b[H\x1b[2J\x1b[1;31mTitle\x1b[m\x1b[4;1H\x1b[7m-- INS --\x1b[0m");
    try std.testing.expectEqual(@as(u21, 'T'), s.row(0)[0].cp);
    try std.testing.expect(s.row(0)[0].attrs.bold);
    try std.testing.expectEqual(theme.ansi[1], s.row(0)[0].fg.?);
    try std.testing.expect(s.row(3)[0].attrs.inverse);
    // Split UTF-8, line drawing, the cursor asked for.
    _ = v.feed("\x1b[2;1H\xe2\x94");
    _ = v.feed("\x80\x1b(0q\x1b(Bq\x1b[6n");
    try std.testing.expectEqual(@as(u21, '─'), s.row(1)[0].cp);
    try std.testing.expectEqual(@as(u21, '─'), s.row(1)[1].cp);
    try std.testing.expectEqual(@as(u21, 'q'), s.row(1)[2].cp);
    try std.testing.expectEqualStrings("\x1b[2;4R", rec.got[0..rec.n]);
    // 24-bit colors in both forms, a region scrolled by a delete.
    _ = v.feed("\x1b[38;2;255;0;0mA\x1b[48:2::0:255:0mB\x1b[m");
    try std.testing.expectEqual(@as(f32, 1), s.row(1)[3].fg.?.r);
    try std.testing.expectEqual(@as(f32, 1), s.row(1)[4].bg.?.g);
    _ = v.feed("\x1b[1;3r\x1b[1;1H\x1b[M");
    try std.testing.expectEqual(@as(u21, '─'), s.row(0)[0].cp);
    try std.testing.expect(s.row(3)[0].attrs.inverse);
    // Asked for its background, it answers; leaving stops at that byte.
    rec.n = 0;
    _ = v.feed("\x1b]11;?\x07");
    try std.testing.expectEqualStrings("\x1b]11;rgb:1616/1414/0f0f\x1b\\", rec.got[0..rec.n]);
    const rest = "\x1b[?1049lafter";
    try std.testing.expectEqual(rest.len - 5, v.feed(rest));
    try std.testing.expect(s.done);
}
