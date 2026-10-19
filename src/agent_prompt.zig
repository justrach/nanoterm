//! A prompt's content as Harness sends it over ACP (prompt_images.rs):
//! the text, with a trailer naming each picture's file, and for an agent
//! that takes images each picture as an `image` block with its `uri`.
const std = @import("std");
const Image = @import("agent.zig").Image;

/// The largest picture sent inline: graff's own limit (Harness's is 5 MiB).
/// A bigger one goes by its path only.
pub const max_inline_bytes = 3_700_000;

/// Harness's trailer: the pictures' files, for an agent to open them.
pub const trailer_header = "Attached images (local files \u{2014} open them to view):";

/// `session/prompt`'s content, as Harness makes it (prompt_images.rs):
/// the text, with a trailer naming each picture's file; then, for an
/// agent that takes images (`images_ok`), each picture as an `image`
/// block with its file's `uri`. The trailer goes once every picture
/// with a file went inline; an agent without images opens the files.
pub fn parts(arena: std.mem.Allocator, text: []const u8, images: []const Image, images_ok: bool) ![]const Part {
    var out: std.ArrayList(Part) = .empty;
    var trailer: std.ArrayList(u8) = .empty;
    var all_inline = true;
    for (images) |*im| {
        const inline_ = images_ok and im.data.len <= max_inline_bytes;
        if (inline_) try out.append(arena, .{ .image = im });
        if (im.path.len == 0) continue;
        all_inline = all_inline and inline_;
        if (trailer.items.len == 0) try trailer.print(arena, "\n\n{s}", .{trailer_header});
        try trailer.print(arena, "\n- {s}", .{im.path});
    }
    const said = if (trailer.items.len > 0 and !all_inline) try std.mem.concat(arena, u8, &.{ text, trailer.items }) else text;
    try out.insert(arena, 0, .{ .text = said });
    return out.items;
}

/// A content block of a prompt: text, or an image in base64.
pub const Part = struct {
    text: []const u8 = "",
    image: ?*const Image = null,

    pub fn jsonStringify(p: Part, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        if (p.image) |im| {
            try jw.write("image");
            try jw.objectField("mimeType");
            try jw.write(im.mime);
            try jw.objectField("data");
            try jw.beginWriteRaw();
            try jw.writer.writeByte('"');
            try std.base64.standard.Encoder.encodeWriter(jw.writer, im.data);
            try jw.writer.writeByte('"');
            jw.endWriteRaw();
            if (im.path.len > 0) {
                try jw.objectField("uri");
                try jw.beginWriteRaw();
                try jw.writer.writeAll("\"file://");
                try writeUriPath(jw.writer, im.path);
                try jw.writer.writeByte('"');
                jw.endWriteRaw();
            }
        } else {
            try jw.write("text");
            try jw.objectField("text");
            try jw.write(p.text);
        }
        try jw.endObject();
    }
};

/// `path` as a file URL's path: its bytes, percent-encoded where a URL needs.
fn writeUriPath(w: *std.Io.Writer, path: []const u8) !void {
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/-._~", ch) != null) {
            try w.writeByte(ch);
        } else try w.print("%{X:0>2}", .{ch});
    }
}

test "a prompt's pictures as Harness sends them: inline with their files, or named" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var data = "\x89PNG\r\n\x1a\n".*;
    var path = "/tmp/my shot.png".*;
    var name = "my shot.png".*;
    const images = [_]Image{.{ .name = &name, .mime = "image/png", .data = &data, .path = &path }};
    // An agent that takes images: inline, with its uri; no trailer.
    const inl = try parts(a, "look", &images, true);
    try std.testing.expectEqual(@as(usize, 2), inl.len);
    try std.testing.expectEqualStrings("look", inl[0].text);
    const json = try std.json.Stringify.valueAlloc(a, inl, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"uri\":\"file:///tmp/my%20shot.png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"image\",\"mimeType\":\"image/png\"") != null);
    // One that doesn't: the text names the file, for it to open.
    const named = try parts(a, "look", &images, false);
    try std.testing.expectEqual(@as(usize, 1), named.len);
    try std.testing.expectEqualStrings("look\n\n" ++ trailer_header ++ "\n- /tmp/my shot.png", named[0].text);
    // Too big to go inline: named, even to an agent that takes images.
    var big_data: [max_inline_bytes + 1]u8 = undefined;
    @memcpy(big_data[0..8], &data);
    const big = [_]Image{.{ .name = &name, .mime = "image/png", .data = &big_data, .path = &path }};
    const by_path = try parts(a, "look", &big, true);
    try std.testing.expectEqual(@as(usize, 1), by_path.len);
    try std.testing.expect(std.mem.endsWith(u8, by_path[0].text, "- /tmp/my shot.png"));
}
