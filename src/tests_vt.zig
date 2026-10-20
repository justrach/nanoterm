//! The terminal's output (vt.zig) fed what shells and programs write: text,
//! colors, carriage returns and OSC; a program drawing in place; and what
//! Windows' pseudo console writes, which moves its cursor to rows where
//! Unix writes line breaks.
const std = @import("std");
const vt = @import("vt.zig");
const Output = vt.Output;

test "lines, colors, carriage returns, OSC" {
    const gpa = std.testing.allocator;
    var o: Output = .init(gpa);
    defer o.deinit();
    const Rec = struct {
        got: [64]u8 = undefined,
        n: usize = 0,
        fn on(ctx: *anyopaque, payload: []const u8) void {
            const r: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(r.got[0..payload.len], payload);
            r.n = payload.len;
        }
    };
    var rec: Rec = .{};
    o.osc_handler = .{ .ctx = &rec, .func = Rec.on };
    try o.feed("plain \x1b[31mred\x1b[0m done\r\n");
    try o.feed("50%\r100%\n");
    try o.feed("step 3\rdone\n");
    try o.feed("\x1b]133;D;0\x07tab\there\n");
    try std.testing.expectEqualStrings("plain red done", o.lines.items[0].text.items);
    try std.testing.expectEqual(@as(usize, 1), o.lines.items[0].spans.items.len);
    try std.testing.expectEqual(@as(u32, 6), o.lines.items[0].spans.items[0].start);
    try std.testing.expectEqual(@as(u32, 9), o.lines.items[0].spans.items[0].end);
    try std.testing.expectEqualStrings("100%", o.lines.items[1].text.items);
    try std.testing.expectEqualStrings("133;D;0", rec.got[0..rec.n]);
    try std.testing.expectEqualStrings("done 3", o.lines.items[2].text.items);
    try std.testing.expectEqualStrings("tab     here", o.lines.items[3].text.items);
    const plain = try o.plainText(gpa);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("plain red done\n100%\ndone 3\ntab     here", plain);
    // Colored text overwritten in part keeps its color where it remains.
    var o2: Output = .init(gpa);
    defer o2.deinit();
    try o2.feed("\x1b[31mabcdef\x1b[0m\rXY\n");
    try std.testing.expectEqualStrings("XYcdef", o2.lines.items[0].text.items);
    try std.testing.expectEqual(@as(u32, 2), o2.lines.items[0].spans.items[0].start);
    try o.feed("\x1b[?1049h\x1b[2;3Hvim");
    try std.testing.expect(o.alternate_screen);
    try std.testing.expectEqual(@as(u21, 'v'), o.full.?.screen.row(1)[2].cp);
    // The screen keeps what it drew out of the lines, and goes on leaving.
    try std.testing.expectEqualStrings("tab     here", o.lines.items[3].text.items);
    try o.feed("\x1b[?1049lback\n");
    try std.testing.expect(o.full == null);
    try std.testing.expectEqualStrings("back", o.lines.items[4].text.items);
}

test "a program drawing in place gets a screen, and its last screen stays" {
    const gpa = std.testing.allocator;
    var o: Output = .{ .gpa = gpa, .inline_ok = true, .cols = 40, .rows = 6 };
    defer o.deinit();
    try o.feed("one\ntwo\n");
    // Bracketed paste on: Claude Code's prompt, redrawn in place.
    try o.feed("\x1b[?2004h\x1b[?25l> 1. Yes\r\n  2. No\r\n");
    try std.testing.expect(o.full != null and !o.alternate_screen);
    try o.feed("\x1b[2A\x1b[2K> 1. Yes, I trust this folder\r\n\r\n");
    const s = o.full.?.screen;
    try std.testing.expectEqual(@as(u21, 'o'), s.row(0)[0].cp);
    try std.testing.expectEqual(@as(u21, 'Y'), s.row(2)[5].cp);
    try std.testing.expectEqual(@as(u21, 'f'), s.row(2)[23].cp);
    // Rows scrolled off its top stay lines.
    try o.feed("a\r\nb\r\nc\r\nd\r\n");
    try std.testing.expectEqualStrings("one", o.lines.items[0].text.items);
    o.leaveScreen();
    const plain = try o.plainText(gpa);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("one\ntwo\n> 1. Yes, I trust this folder\n  2. No\na\nb\nc\nd", plain);
    // The shell's own output between commands never takes a screen.
    var shell: Output = .init(gpa);
    defer shell.deinit();
    try shell.feed("\x1b[?2004hprompt");
    try std.testing.expect(shell.full == null);
}


/// What PowerShell 7 wrote on a pseudo console on Windows for
/// `Write-Output one; Get-ChildItem C:\Windows\Web; Write-Output two`.
const pwsh_listing = "\x1b[?9001h\x1b[?1004h\x1b[?25l\x1b[2J\x1b[m\x1b[H\x1b]0;Administrator: C:\\Program Files\\PowerShell\\7\\pwsh.exe\x07\x1b[?25hone\r\n\r\n\x1b[?25l    Directory: C:\\Windows\\Web\x1b[32m\x1b[1m\x1b[5;1HMode                 LastWriteTime\x1b[m \x1b[32m\x1b[1m\x1b[3m        Length\x1b[23m Name\r\n----   \x1b[m \x1b[32m\x1b[1m             -------------\x1b[m \x1b[32m\x1b[1m        ------\x1b[m \x1b[32m\x1b[1m----\x1b[m\r\nd----            4/1/2024  8:12 AM\x1b[16X\x1b[44m\x1b[1m\x1b[16C4K\x1b[m\r\nd-r--            4/1/2024  8:12 AM\x1b[16X\x1b[44m\x1b[1m\x1b[16CScreen\x1b[m\r\nd----            4/1/2024  8:12 AM\x1b[16X\x1b[44m\x1b[1m\x1b[16CWallpaper\x1b[m\r\ntwo\x1b[12;1H\x1b[?25h\x1b[?9001l\x1b[?1004l";

test "Windows' pseudo console: a move down to a row is line breaks" {
    const gpa = std.testing.allocator;
    var cursor: vt.Cursor = .{ .rows = 30 };
    var o: Output = .{ .gpa = gpa, .cursor = &cursor, .cols = 100, .rows = 30 };
    defer o.deinit();
    // In two reads, split inside the move.
    try o.feed(pwsh_listing[0..200]);
    try o.feed(pwsh_listing[200..]);
    const plain = try o.plainText(gpa);
    defer gpa.free(plain);
    var lines = std.mem.splitScalar(u8, plain, '\n');
    const want = [_][]const u8{ "one", "", "    Directory: C:\\Windows\\Web", "", "Mode                 LastWriteTime         Length Name" };
    for (want) |w| try std.testing.expectEqualStrings(w, std.mem.trimEnd(u8, lines.next().?, " "));
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "----"));
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "4K"));
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "Screen"));
    try std.testing.expect(std.mem.endsWith(u8, lines.next().?, "Wallpaper"));
    try std.testing.expectEqualStrings("two", lines.next().?);
    // Without the cursor (zsh's output), a move to a row is ignored, as before.
    var unix: Output = .init(gpa);
    defer unix.deinit();
    try unix.feed("a\x1b[5;1Hb\n");
    try std.testing.expectEqualStrings("ab", unix.lines.items[0].text.items);
}

test "Windows' pseudo console: wrapped lines and moves up keep the count" {
    const gpa = std.testing.allocator;
    var cursor: vt.Cursor = .{ .rows = 10 };
    var o: Output = .{ .gpa = gpa, .cursor = &cursor, .cols = 10, .rows = 10 };
    defer o.deinit();
    // 25 characters on a console 10 wide: rows 0, 1 and 2.
    try o.feed("abcdefghijklmnopqrstuvwxy");
    try std.testing.expectEqual(@as(u32, 2), cursor.row);
    // Row 4 (CSI 5;1H) is two rows down: one blank line between.
    try o.feed("\x1b[5;1Hnext");
    try std.testing.expectEqual(@as(usize, 3), o.lines.items.len);
    try std.testing.expectEqualStrings("next", o.lines.items[2].text.items);
    // Up, then down past where it was: only the rows past the last line are new.
    try o.feed("\x1b[2;1H\x1b[7;1Hlast");
    try std.testing.expectEqual(@as(usize, 5), o.lines.items.len);
    try std.testing.expectEqualStrings("last", o.lines.items[4].text.items);
}

test "Windows' pseudo console: a repaint from the top doesn't cost a block its lines" {
    const gpa = std.testing.allocator;
    var cursor: vt.Cursor = .{ .rows = 20 };
    // The shell between commands: ten rows, then a repaint from the top
    // (a resize), two rows of it.
    var between: Output = .{ .gpa = gpa, .cursor = &cursor, .follow = true, .cols = 80, .rows = 20 };
    defer between.deinit();
    for (0..10) |_| try between.feed("x\r\n");
    try between.feed("\x1b[Ha\r\nb\r\n");
    try std.testing.expectEqual(@as(u32, 2), cursor.row);
    // A command's output from there: row 5 (CSI 6;1H) is past a blank row.
    var block: Output = .{ .gpa = gpa, .cursor = &cursor, .line_row = cursor.row, .cols = 80, .rows = 20 };
    defer block.deinit();
    try block.feed("\r\n    Directory\x1b[6;1HMode");
    const plain = try block.plainText(gpa);
    defer gpa.free(plain);
    try std.testing.expectEqualStrings("    Directory\n\nMode", plain);
}
