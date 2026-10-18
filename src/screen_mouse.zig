//! The mouse for full-screen programs that ask for it (Claude Code, vim
//! with `mouse=a`, htop): presses, releases, drags and moves sent as xterm
//! reports at the cell under the pointer, and the wheel as buttons 64 and
//! 65, so the program scrolls and selects for itself. Shift keeps the
//! pointer nanoterm's, to select the screen's text, as in other terminals.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const Screen = @import("screen.zig").Screen;
const Session = @import("session.zig").Session;
const view_screen = @import("view_screen.zig");

/// Whether the program has the pointer now (else nanoterm selects).
pub fn tracking(c: *const ui.Context, s: *const Screen) bool {
    return s.mouse != .off and (!c.input.shift or s.mouse_held);
}

/// A report as xterm sends it: SGR's `CSI < b ; x ; y M` (m for a
/// release) when the program asked for it, else the old `CSI M` and three
/// bytes offset by 32. Cells count from 0 here, from 1 in the report.
pub fn report(buf: []u8, sgr: bool, button: u8, cell: [2]u16, release: bool) []const u8 {
    if (sgr) return std.fmt.bufPrint(buf, "\x1b[<{d};{d};{d}{c}", .{ button, cell[0] + 1, cell[1] + 1, @as(u8, if (release) 'm' else 'M') }) catch "";
    buf[0..3].* = "\x1b[M".*;
    // The old form has no release of a button: "3" says one came up.
    buf[3] = 32 + if (release) (button & ~@as(u8, 3)) | 3 else button;
    buf[4] = @intCast(32 + @min(@as(u32, cell[0]) + 1, 223));
    buf[5] = @intCast(32 + @min(@as(u32, cell[1]) + 1, 223));
    return buf[0..6];
}

const At = struct { cell: [2]u16, inside: bool };

/// The cell under the pointer (held to the screen's edges) and whether
/// the pointer is on the screen at all.
fn at(c: *ui.Context, s: *const Screen) ?At {
    const o = s.origin orelse return null;
    const m = view_screen.metrics(c);
    const fx = (c.input.mouse.x - o[0]) / m.w;
    const fy = (c.input.mouse.y - o[1]) / m.h;
    const cols: f32 = @floatFromInt(s.cols);
    const rows: f32 = @floatFromInt(s.rows);
    return .{
        .cell = .{ @intFromFloat(std.math.clamp(@floor(fx), 0, cols - 1)), @intFromFloat(std.math.clamp(@floor(fy), 0, rows - 1)) },
        .inside = fx >= 0 and fy >= 0 and fx < cols and fy < rows,
    };
}

fn mods(c: *const ui.Context) u8 {
    return if (c.input.ctrl) 16 else 0;
}

/// This frame's pointer, for a program that tracks it.
pub fn pointer(c: *ui.Context, a: *Session, s: *Screen) void {
    if (s.mouse == .motion) c.wants_moves = true;
    if (!tracking(c, s)) return;
    const p = at(c, s) orelse return;
    var buf: [32]u8 = undefined;
    if (c.input.pressed) {
        if (!p.inside) return;
        s.mouse_held = true;
        s.mouse_cell = p.cell;
        a.shell.input(report(&buf, s.mouse_sgr, mods(c), p.cell, false));
    } else if (c.input.released) {
        if (!s.mouse_held) return;
        s.mouse_held = false;
        a.shell.input(report(&buf, s.mouse_sgr, mods(c), p.cell, true));
    } else if (!std.mem.eql(u16, &p.cell, &s.mouse_cell)) {
        // A drag (button 0, plus 32 for motion), or a move with none (3).
        if (s.mouse_held and s.mouse != .press) {
            a.shell.input(report(&buf, s.mouse_sgr, 32 | mods(c), p.cell, false));
        } else if (!s.mouse_held and s.mouse == .motion and p.inside) {
            a.shell.input(report(&buf, s.mouse_sgr, 32 | 3 | mods(c), p.cell, false));
        } else return;
        s.mouse_cell = p.cell;
    }
}

/// The wheel as the program's buttons 4 and 5 (64 and 65), a report a
/// line, at the cell under the pointer.
pub fn wheel(c: *ui.Context, a: *Session, s: *Screen, up: bool) void {
    const p = at(c, s) orelse return;
    var buf: [32]u8 = undefined;
    a.shell.input(report(&buf, s.mouse_sgr, @as(u8, if (up) 64 else 65) | mods(c), p.cell, false));
}

test "mouse reports, in SGR's form and the old one" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[<0;5;3M", report(&buf, true, 0, .{ 4, 2 }, false));
    try std.testing.expectEqualStrings("\x1b[<0;5;3m", report(&buf, true, 0, .{ 4, 2 }, true));
    try std.testing.expectEqualStrings("\x1b[<64;1;1M", report(&buf, true, 64, .{ 0, 0 }, false));
    try std.testing.expectEqualStrings("\x1b[M\x20\x25\x23", report(&buf, false, 0, .{ 4, 2 }, false));
    try std.testing.expectEqualStrings("\x1b[M\x23\x25\x23", report(&buf, false, 0, .{ 4, 2 }, true));
    // Past column 222 the old form can't say more.
    try std.testing.expectEqual(@as(u8, 255), report(&buf, false, 0, .{ 500, 0 }, false)[4]);
}
