//! The pictures Markdown shows (`![alt](path)`, `<img>`): local image files
//! (an absolute path, `~/…`, or `file://…`), read once and kept for nanoui
//! to decode; and, where the app allows it (`fetch`), pictures on the web,
//! downloaded in the background into nanoterm's cache (a README's badges:
//! shields.io's come as PNG from its raster service), drawn once they come.
const std = @import("std");
const web = @import("web.zig");

/// Files larger than this are not read.
const max_bytes = 32 * 1024 * 1024;
const extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".bmp", ".tif", ".tiff" };

pub const Cache = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    /// By source as written; null when it could not be read.
    map: std.StringHashMapUnmanaged(?[]u8) = .empty,
    /// Pictures on the web are downloaded (the app; never in tests).
    fetch: bool = false,
    downloads: std.ArrayList(*Download) = .empty,
    /// A download came: draw again.
    changed: ?struct { ctx: *anyopaque, func: *const fn (*anyopaque) void } = null,

    pub fn deinit(cache: *Cache) void {
        for (cache.downloads.items) |d| {
            d.call.deinit();
            cache.gpa.free(d.src);
            cache.gpa.destroy(d);
        }
        cache.downloads.deinit(cache.gpa);
        var it = cache.map.iterator();
        while (it.next()) |e| {
            cache.gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |b| cache.gpa.free(b);
        }
        cache.map.deinit(cache.gpa);
    }

    /// The file `src` names, if it is a local picture or one downloaded.
    pub fn get(cache: *Cache, src: []const u8) ?[]const u8 {
        if (cache.map.get(src)) |v| return v;
        if (std.mem.startsWith(u8, src, "https://") or std.mem.startsWith(u8, src, "http://")) return cache.remote(src);
        const bytes = cache.read(src);
        const key = cache.gpa.dupe(u8, src) catch {
            if (bytes) |b| cache.gpa.free(b);
            return null;
        };
        cache.map.put(cache.gpa, key, bytes) catch {
            cache.gpa.free(key);
            if (bytes) |b| cache.gpa.free(b);
            return null;
        };
        return bytes;
    }

    /// A picture on the web: from the cache folder, else downloading.
    fn remote(cache: *Cache, src: []const u8) ?[]const u8 {
        if (!cache.fetch) return null;
        for (cache.downloads.items) |d| if (std.mem.eql(u8, d.src, src)) return null;
        var buf: [1024]u8 = undefined;
        const path = cache.cachePath(&buf, src) orelse return null;
        if (std.Io.Dir.cwd().readFileAlloc(cache.io, path, cache.gpa, .limited(max_bytes))) |bytes| {
            cache.keep(src, picture(bytes, cache.gpa));
            return cache.map.get(src) orelse null;
        } else |_| {}
        const d = cache.gpa.create(Download) catch return null;
        d.* = .{ .cache = cache, .src = cache.gpa.dupe(u8, src) catch {
            cache.gpa.destroy(d);
            return null;
        }, .call = .{ .gpa = cache.gpa } };
        if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(cache.io, dir) catch {};
        d.call.start(.{ .url = raster(&d.url_buf, src), .output = path, .max_seconds = 20, .max_bytes = max_bytes }, .{ .ctx = d, .func = Download.done }) catch {
            cache.gpa.free(d.src);
            cache.gpa.destroy(d);
            cache.keep(src, null);
            return null;
        };
        cache.downloads.append(cache.gpa, d) catch {};
        return null;
    }

    /// Where a picture from the web is kept: named by its address's hash.
    fn cachePath(cache: *Cache, buf: []u8, src: []const u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/Library/Caches/nanoterm/pictures/{x:0>16}", .{ cache.home, std.hash.Wyhash.hash(0, src) }) catch null;
    }

    fn keep(cache: *Cache, src: []const u8, bytes: ?[]u8) void {
        const key = cache.gpa.dupe(u8, src) catch {
            if (bytes) |b| cache.gpa.free(b);
            return;
        };
        cache.map.put(cache.gpa, key, bytes) catch {
            cache.gpa.free(key);
            if (bytes) |b| cache.gpa.free(b);
        };
    }

    fn read(cache: *Cache, src: []const u8) ?[]u8 {
        var buf: [4096]u8 = undefined;
        const path = resolve(&buf, cache.home, src) orelse return null;
        return std.Io.Dir.cwd().readFileAlloc(cache.io, path, cache.gpa, .limited(max_bytes)) catch null;
    }
};

/// A download of a picture on the web, into the cache folder.
const Download = struct {
    cache: *Cache,
    src: []u8,
    call: web.Call,
    url_buf: [2048]u8 = undefined,

    fn done(ctx: *anyopaque, code: i32, _: []const u8) void {
        const d: *Download = @ptrCast(@alignCast(ctx));
        const cache = d.cache;
        var buf: [1024]u8 = undefined;
        const path = cache.cachePath(&buf, d.src);
        const bytes: ?[]u8 = if (code == 0 and path != null) std.Io.Dir.cwd().readFileAlloc(cache.io, path.?, cache.gpa, .limited(max_bytes)) catch null else null;
        // A failed or unreadable download isn't asked for again this run.
        if (bytes == null) if (path) |p| std.Io.Dir.cwd().deleteFile(cache.io, p) catch {};
        cache.keep(d.src, if (bytes) |b| picture(b, cache.gpa) else null);
        for (cache.downloads.items, 0..) |x, i| if (x == d) {
            _ = cache.downloads.swapRemove(i);
            break;
        };
        // The call ended: it frees once its callback returns.
        cache.gpa.free(d.src);
        d.call.body.deinit(cache.gpa);
        cache.gpa.destroy(d);
        if (cache.changed) |c| c.func(c.ctx);
    }
};

/// The bytes, unless they are an SVG (which can't be decoded here).
fn picture(bytes: []u8, gpa: std.mem.Allocator) ?[]u8 {
    const head = std.mem.trimStart(u8, bytes[0..@min(bytes.len, 256)], " \t\r\n\xef\xbb\xbf");
    if (std.mem.startsWith(u8, head, "<svg") or std.mem.startsWith(u8, head, "<?xml")) {
        gpa.free(bytes);
        return null;
    }
    return bytes;
}

/// shields.io's badges are SVG; its raster service draws the same as PNG.
fn raster(buf: []u8, src: []const u8) []const u8 {
    const shields = "https://img.shields.io/";
    if (std.mem.startsWith(u8, src, shields)) return std.fmt.bufPrint(buf, "https://raster.shields.io/{s}", .{src[shields.len..]}) catch src;
    return src;
}

/// The file path of `src`, or null if it is not a local picture.
pub fn resolve(buf: []u8, home: []const u8, src_in: []const u8) ?[]const u8 {
    var src = src_in;
    if (std.mem.startsWith(u8, src, "file://")) src = src["file://".len..];
    if (std.mem.indexOf(u8, src, "://") != null) return null;
    var ok = false;
    for (extensions) |e| {
        if (src.len >= e.len and std.ascii.eqlIgnoreCase(src[src.len - e.len ..], e)) ok = true;
    }
    if (!ok) return null;
    if (std.mem.startsWith(u8, src, "~/")) return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, src[2..] }) catch null;
    if (!std.fs.path.isAbsolute(src)) return null;
    return src;
}

test "local pictures only" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/tmp/a.png", resolve(&buf, "/h", "/tmp/a.png").?);
    try std.testing.expectEqualStrings("/h/x/b.JPG", resolve(&buf, "/h", "~/x/b.JPG").?);
    try std.testing.expectEqualStrings("/tmp/c.png", resolve(&buf, "/h", "file:///tmp/c.png").?);
    try std.testing.expect(resolve(&buf, "/h", "https://example.com/a.png") == null);
    try std.testing.expect(resolve(&buf, "/h", "/etc/passwd") == null);
    try std.testing.expect(resolve(&buf, "/h", "relative.png") == null);
    var ub: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https://raster.shields.io/badge/license-MIT-blue", raster(&ub, "https://img.shields.io/badge/license-MIT-blue"));
    try std.testing.expectEqualStrings("https://x.io/a.png", raster(&ub, "https://x.io/a.png"));
}
