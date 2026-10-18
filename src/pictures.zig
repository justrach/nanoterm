//! The pictures agents' answers show (`![alt](path)`): local image files
//! only (an absolute path, `~/…`, or `file://…`; nothing is fetched from the
//! network), read once and kept for nanoui to decode.
const std = @import("std");

/// Files larger than this are not read.
const max_bytes = 32 * 1024 * 1024;
const extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".bmp", ".tif", ".tiff" };

pub const Cache = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    /// By source as written; null when it could not be read.
    map: std.StringHashMapUnmanaged(?[]u8) = .empty,

    pub fn deinit(cache: *Cache) void {
        var it = cache.map.iterator();
        while (it.next()) |e| {
            cache.gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |b| cache.gpa.free(b);
        }
        cache.map.deinit(cache.gpa);
    }

    /// The file `src` names, if it is a local picture.
    pub fn get(cache: *Cache, src: []const u8) ?[]const u8 {
        if (cache.map.get(src)) |v| return v;
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

    fn read(cache: *Cache, src: []const u8) ?[]u8 {
        var buf: [4096]u8 = undefined;
        const path = resolve(&buf, cache.home, src) orelse return null;
        return std.Io.Dir.cwd().readFileAlloc(cache.io, path, cache.gpa, .limited(max_bytes)) catch null;
    }
};

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
}
