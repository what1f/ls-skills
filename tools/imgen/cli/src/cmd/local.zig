//! Shared by the local commands (cutout, resize): PNG in, PNG out.
const std = @import("std");
const clikit = @import("clikit");
const Ctx = @import("../ctx.zig").Ctx;
const png = @import("../image/png.zig");
const sniff = @import("../image/sniff.zig");
const output = @import("../output.zig");
const Failure = clikit.Failure;

pub const Loaded = union(enum) {
    image: png.Image,
    fail: Failure,
};

/// Reads and decodes a PNG; the image is owned by `ctx.gpa`.
pub fn load(ctx: Ctx, path: []const u8) !Loaded {
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.gpa, .limited(200 << 20)) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return .{ .fail = .{ .code = "usage", .message = try std.fmt.allocPrint(ctx.arena, "{s}: cannot read ({s})", .{ path, @errorName(err) }) } },
    };
    defer ctx.gpa.free(data);
    const info = sniff.sniff(data);
    if (info == null or info.?.format != .png) {
        const what = if (info) |i| @tagName(i.format) else "not an image";
        return .{ .fail = .{ .code = "unsupported", .message = try std.fmt.allocPrint(ctx.arena, "{s}: only PNG is supported ({s}); convert it first, e.g. `sips -s format png in.jpg --out in.png` on macOS", .{ path, what }) } };
    }
    const img = png.decode(ctx.gpa, data) catch |err| return switch (err) {
        error.OutOfMemory => |e| e,
        error.Interlaced => .{ .fail = .{ .code = "unsupported", .message = try std.fmt.allocPrint(ctx.arena, "{s}: interlaced PNG is not supported", .{path}) } },
        error.Invalid => .{ .fail = .{ .code = "unsupported", .message = try std.fmt.allocPrint(ctx.arena, "{s}: corrupt or unreadable PNG", .{path}) } },
    };
    return .{ .image = img };
}

/// Encodes and writes; returns the byte count or a failure.
pub fn save(ctx: Ctx, path: []const u8, img: png.Image, force: bool) !union(enum) { bytes: usize, fail: Failure } {
    const data = try png.encode(ctx.gpa, img);
    defer ctx.gpa.free(data);
    if (output.writeFile(ctx.io, path, data, force)) |f| return .{ .fail = f };
    return .{ .bytes = data.len };
}

/// `--out` must be a .png path, and must not exist unless `force`.
pub fn checkOut(ctx: Ctx, path: []const u8, force: bool) !?Failure {
    if (sniff.Format.fromExt(path) != .png) return .{ .code = "usage", .message = "--out must end in .png" };
    if (!force and output.fileExists(ctx.io, path)) return .{ .code = "exists", .message = try std.fmt.allocPrint(ctx.arena, "{s} already exists (use --force to overwrite)", .{path}) };
    return null;
}

pub fn exitFor(f: Failure) u8 {
    const eql = std.mem.eql;
    if (eql(u8, f.code, "write_failed")) return clikit.exit.failure;
    return clikit.exit.usage;
}
