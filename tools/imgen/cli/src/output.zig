//! Output paths: planning names for N images, existence checks and
//! extension fixes.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Format = @import("image/sniff.zig").Format;

pub const Target = union(enum) {
    /// `--out FILE`: used as is for one image, `-1`, `-2`… suffixes for more.
    file: []const u8,
    /// `--out-dir DIR`: `image-N` with the first free N.
    dir: []const u8,
};

/// Plans `count` output paths with `format`'s extension. `exists` decides whether a path is taken; in
/// dir mode taken names are skipped, in file mode they are returned and the
/// caller reports them.
pub fn plan(
    gpa: Allocator,
    target: Target,
    count: usize,
    format: Format,
    ctx: anytype,
    comptime exists: fn (@TypeOf(ctx), []const u8) bool,
) Allocator.Error![][]const u8 {
    const paths = try gpa.alloc([]const u8, count);
    switch (target) {
        .file => |file| {
            // A recognised image extension is replaced to match the format;
            // anything else is kept and the format's extension appended.
            const ext = std.fs.path.extension(file);
            const known = Format.fromExt(file) != null;
            const stem = if (known) file[0 .. file.len - ext.len] else file;
            const use_ext = format.ext();
            for (paths, 0..) |*p, i| {
                p.* = if (count == 1)
                    try std.fmt.allocPrint(gpa, "{s}{s}", .{ stem, use_ext })
                else
                    try std.fmt.allocPrint(gpa, "{s}-{d}{s}", .{ stem, i + 1, use_ext });
            }
        },
        .dir => |dir| {
            var n: usize = 1;
            for (paths) |*p| {
                while (true) : (n += 1) {
                    const candidate = try std.fmt.allocPrint(gpa, "image-{d}{s}", .{ n, format.ext() });
                    const full = if (std.mem.eql(u8, dir, ".")) candidate else try std.fs.path.join(gpa, &.{ dir, candidate });
                    if (!exists(ctx, full)) {
                        p.* = full;
                        n += 1;
                        break;
                    }
                }
            }
        },
    }
    return paths;
}

/// Returns `path` with its extension replaced to match `actual`, or null when
/// it already matches.
pub fn fixExt(gpa: Allocator, path: []const u8, actual: Format) Allocator.Error!?[]const u8 {
    if (Format.fromExt(path) == actual) return null;
    const ext = std.fs.path.extension(path);
    return try std.fmt.allocPrint(gpa, "{s}{s}", .{ path[0 .. path.len - ext.len], actual.ext() });
}

pub fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn noneExist(_: void, _: []const u8) bool {
    return false;
}

fn takenFirstTwo(_: void, p: []const u8) bool {
    return std.mem.endsWith(u8, p, "image-1.png") or std.mem.endsWith(u8, p, "image-2.png");
}

test "plan file" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try plan(a, .{ .file = "out/logo.png" }, 1, .png, {}, noneExist);
    try std.testing.expectEqualStrings("out/logo.png", one[0]);
    const many = try plan(a, .{ .file = "out/logo" }, 2, .png, {}, noneExist);
    try std.testing.expectEqualStrings("out/logo-1.png", many[0]);
    try std.testing.expectEqualStrings("out/logo-2.png", many[1]);
    const swapped = try plan(a, .{ .file = "logo.webp" }, 1, .png, {}, noneExist);
    try std.testing.expectEqualStrings("logo.png", swapped[0]);
    const kept = try plan(a, .{ .file = "logo.v2" }, 1, .png, {}, noneExist);
    try std.testing.expectEqualStrings("logo.v2.png", kept[0]);
}

test "plan dir skips taken names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const paths = try plan(arena.allocator(), .{ .dir = "out" }, 2, .png, {}, takenFirstTwo);
    try std.testing.expectEqualStrings("out" ++ std.fs.path.sep_str ++ "image-3.png", paths[0]);
    try std.testing.expectEqualStrings("out" ++ std.fs.path.sep_str ++ "image-4.png", paths[1]);
}

test "fix ext" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(null, try fixExt(arena.allocator(), "a.png", .png));
    try std.testing.expectEqualStrings("a.png", (try fixExt(arena.allocator(), "a.jpg", .png)).?);
}
