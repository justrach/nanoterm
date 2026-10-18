//! Pictures in answers: `![alt](path)` to a local image is drawn, with its
//! alt text as a caption; a paragraph of only pictures loses the links; a
//! remote picture stays a link.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const view_markdown = @import("view_markdown.zig");
const pictures = @import("pictures.zig");
const theme = @import("theme.zig");

const Page = struct {
    src: []const u8,
    fn view(p: *Page, c: *ui.Context) void {
        const d = ui.div(c).column().sizeFull().p(20).bg(theme.background);
        defer d.end();
        view_markdown.markdown(c, p.src);
    }
};

test "an answer's pictures, drawn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/nanoterm-test-pictures";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    // A 320×200 picture: a warm gradient.
    const px = try gpa.alloc(u8, 320 * 200 * 4);
    defer gpa.free(px);
    for (0..200) |y| for (0..320) |x| {
        px[(y * 320 + x) * 4 ..][0..4].* = .{ @intCast(60 + y / 2), @intCast(120 + x / 4), 230, 255 };
    };
    const png = try @import("nanoui").ui.png.encode(gpa, .{ .bytes = px, .width = 320, .height = 200 });
    defer gpa.free(png);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/light.png", .data = png });

    var cache: pictures.Cache = .{ .gpa = gpa, .io = io, .home = "/tmp" };
    defer cache.deinit();
    view_markdown.pictures = &cache;
    defer view_markdown.pictures = null;
    var page: Page = .{ .src = "Here is the gallery.\n\n**Light mode** ![Gallery in light mode](" ++ dir ++ "/light.png)\n\n![Just the picture](" ++ dir ++ "/light.png)\n\nRemote: ![logo](https://example.com/logo.png)" };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&page, Page.view), .{ .width = 760, .height = 900, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    var images: usize = 0;
    for (t.ctx.nodes.items) |n| if (n.content == .image) {
        images += 1;
        // 320×200 pixels: 160×100 points.
        try std.testing.expectEqual(@as(f32, 160), n.rect.w);
    };
    try std.testing.expectEqual(@as(usize, 2), images);
    try std.testing.expect(t.hasText("Gallery in light mode"));
    try std.testing.expect(t.containsText("Light mode"));
    // The picture-only paragraph is just the picture and its caption.
    try std.testing.expect(t.hasText("Just the picture"));
    try std.testing.expect(t.containsText("Remote: logo"));
    try t.screenshot("/tmp/nanoterm-pictures.png");
}

test "scrolling past many pictures doesn't decode or pack them again every frame" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const dir = "/tmp/nanoterm-test-pictures-scroll";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    // Eight different 1600×1000 pictures: more than the atlas holds at once.
    const px = try gpa.alloc(u8, 1600 * 1000 * 4);
    defer gpa.free(px);
    @memset(px, 200);
    const png = try ui.png.encode(gpa, .{ .bytes = px, .width = 1600, .height = 1000 });
    defer gpa.free(png);
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    for (0..8) |k| {
        var name: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, dir ++ "/shot{d}.png", .{k});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = png });
        try src.print(gpa, "Paragraph {d} of the answer, with some words to wrap.\n\n![shot {d}]({s})\n\n", .{ k, k, path });
    }
    var cache: pictures.Cache = .{ .gpa = gpa, .io = io, .home = "/tmp" };
    defer cache.deinit();
    view_markdown.pictures = &cache;
    defer view_markdown.pictures = null;
    const Scroller = struct {
        src: []const u8,
        fn view(p: *@This(), c: *ui.Context) void {
            const d = c.open(.{ .direction = .column, .width = .fill, .height = .fill, .scroll = true, .padding = .all(20) }, null);
            defer c.end();
            _ = d;
            view_markdown.markdown(c, p.src);
        }
    };
    var page: Scroller = .{ .src = src.items };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&page, Scroller.view), .{ .width = 760, .height = 700, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    const before = t.text.images.generation;
    for (0..40) |_| t.scroll(300, 300, -60);
    for (0..40) |_| t.scroll(300, 300, 60);
    // Each picture packed when it comes into view, not every frame.
    try std.testing.expect(t.text.images.generation - before < 40);
    try std.testing.expectEqual(@as(usize, 8), t.text.images.decoded.count());
}
