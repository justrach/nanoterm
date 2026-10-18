//! Pictures in the input, for the agent: pasted (⌘V with an image or image
//! files on the clipboard), or chosen with the paperclip. They wait as
//! chips above the input and go with the next prompt.
const std = @import("std");
const nanoui = @import("nanoui");
const agent_mod = @import("agent.zig");
const Image = agent_mod.Image;
const Workspace = @import("workspace.zig").Workspace;

/// The largest picture taken: agents refuse bigger ones anyway.
pub const max_bytes = 20 << 20;
pub const extensions = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp" };

/// What a picture is, from its first bytes; null if not one agents take.
pub fn mimeOf(data: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return "image/png";
    if (std.mem.startsWith(u8, data, "\xff\xd8\xff")) return "image/jpeg";
    if (std.mem.startsWith(u8, data, "GIF87a") or std.mem.startsWith(u8, data, "GIF89a")) return "image/gif";
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return "image/webp";
    return null;
}

/// Pictures waiting to go with the next prompt.
pub const Tray = struct {
    gpa: std.mem.Allocator,
    items: std.ArrayList(Image) = .empty,
    /// Why the last picture was refused, for the input to show.
    problem: ?[]const u8 = null,
    pasted: u32 = 0,

    pub fn deinit(t: *Tray) void {
        for (t.items.items) |im| im.free(t.gpa);
        t.items.deinit(t.gpa);
    }

    /// Adds `data` (copied) as `name`; false, with a reason, if it is not a picture.
    pub fn add(t: *Tray, name: []const u8, data: []const u8) bool {
        if (data.len > max_bytes) return t.refuse("too large: pictures up to 20 MB");
        const mime = mimeOf(data) orelse return t.refuse("not a PNG, JPEG, GIF or WebP picture");
        const n = t.gpa.dupe(u8, name) catch return false;
        const d = t.gpa.dupe(u8, data) catch {
            t.gpa.free(n);
            return false;
        };
        t.items.append(t.gpa, .{ .name = n, .mime = mime, .data = d }) catch {
            t.gpa.free(n);
            t.gpa.free(d);
            return false;
        };
        t.problem = null;
        return true;
    }

    fn refuse(t: *Tray, why: []const u8) bool {
        t.problem = why;
        return false;
    }

    /// Adds the picture at `path`.
    pub fn addPath(t: *Tray, io: std.Io, path: []const u8) bool {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, t.gpa, .limited(max_bytes + 1)) catch return t.refuse("could not read the file");
        defer t.gpa.free(data);
        return t.add(std.fs.path.basename(path), data);
    }

    /// A picture pasted without a file: "Pasted image 2.png".
    pub fn addPasted(t: *Tray, png: []const u8) bool {
        t.pasted += 1;
        var buf: [48]u8 = undefined;
        const name = if (t.pasted == 1) "Pasted image.png" else std.fmt.bufPrint(&buf, "Pasted image {d}.png", .{t.pasted}) catch "Pasted image.png";
        return t.add(name, png);
    }

    pub fn remove(t: *Tray, i: usize) void {
        if (i >= t.items.items.len) return;
        t.items.orderedRemove(i).free(t.gpa);
    }

    /// The pictures, now the caller's (free each and the slice with `gpa`).
    pub fn take(t: *Tray) []Image {
        t.problem = null;
        if (t.items.items.len == 0) return &.{};
        return t.items.toOwnedSlice(t.gpa) catch &.{};
    }
};

/// ⌘V: an image on the clipboard, or image files copied in Finder, join
/// the tray; true if any did (text is left for the input to paste).
pub fn paste(t: *Tray, io: std.Io) bool {
    if (nanoui.clipboard.readFiles(t.gpa) catch null) |paths| {
        defer nanoui.dialog.freePaths(t.gpa, paths);
        var any = false;
        for (paths) |p| {
            const ext = std.fs.path.extension(p);
            const known = for (extensions) |e| {
                if (ext.len > 1 and std.ascii.eqlIgnoreCase(ext[1..], e)) break true;
            } else false;
            if (known and t.addPath(io, p)) any = true;
        }
        if (any) return true;
    }
    const png = (nanoui.clipboard.readImage(t.gpa) catch null) orelse return false;
    defer t.gpa.free(png);
    return t.addPasted(png);
}

/// The paperclip: an open panel for pictures, run after the frame (a modal
/// panel must not run inside one); they join the focused pane's tray.
pub fn choose(w: *Workspace) void {
    nanoui.App.after(0, w, chooseNow);
}

fn chooseNow(ctx: ?*anyopaque) callconv(.c) void {
    const w: *Workspace = @ptrCast(@alignCast(ctx.?));
    const s = w.focused();
    const paths = (nanoui.dialog.open(s.gpa, .{ .title = "Attach Pictures", .button = "Attach", .multiple = true, .extensions = &extensions, .directory = s.cwd() }) catch null) orelse return;
    defer nanoui.dialog.freePaths(s.gpa, paths);
    for (paths) |p| _ = s.attachments.addPath(s.io, p);
    s.shared.redraw();
}

/// A size as people read one: "312 KB".
pub fn size(buf: []u8, bytes: usize) []const u8 {
    if (bytes < 1024) return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "";
    if (bytes < 1024 * 1024) return std.fmt.bufPrint(buf, "{d} KB", .{bytes / 1024}) catch "";
    return std.fmt.bufPrint(buf, "{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / (1024 * 1024)}) catch "";
}

test "pictures are known by their bytes, and the tray owns them" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("image/png", mimeOf("\x89PNG\r\n\x1a\n....").?);
    try std.testing.expectEqualStrings("image/jpeg", mimeOf("\xff\xd8\xff\xe0").?);
    try std.testing.expectEqualStrings("image/webp", mimeOf("RIFF\x00\x00\x00\x00WEBPVP8 ").?);
    try std.testing.expect(mimeOf("# a readme") == null);
    var t: Tray = .{ .gpa = gpa };
    defer t.deinit();
    try std.testing.expect(!t.add("notes.txt", "hello"));
    try std.testing.expect(t.problem != null);
    try std.testing.expect(t.addPasted("\x89PNG\r\n\x1a\nxx"));
    try std.testing.expect(t.addPasted("\x89PNG\r\n\x1a\nyy"));
    try std.testing.expectEqualStrings("Pasted image 2.png", t.items.items[1].name);
    t.remove(0);
    const taken = t.take();
    defer {
        for (taken) |im| im.free(gpa);
        gpa.free(taken);
    }
    try std.testing.expectEqual(@as(usize, 1), taken.len);
    try std.testing.expectEqual(@as(usize, 0), t.items.items.len);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("312 KB", size(&buf, 312 * 1024));
}
