//! Area-average (box filter) downscaling of RGBA8 images.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("png.zig").Image;

pub const Target = union(enum) {
    max_dim: u32,
    width: u32,
    height: u32,
};

/// The size `target` asks for, keeping the aspect ratio and never enlarging.
pub fn fit(width: u32, height: u32, target: Target) struct { w: u32, h: u32 } {
    const wf: f64 = @floatFromInt(width);
    const hf: f64 = @floatFromInt(height);
    const scale: f64 = @min(1, switch (target) {
        .max_dim => |m| @as(f64, @floatFromInt(m)) / @max(wf, hf),
        .width => |v| @as(f64, @floatFromInt(v)) / wf,
        .height => |v| @as(f64, @floatFromInt(v)) / hf,
    });
    return .{
        .w = @max(1, @as(u32, @intFromFloat(@round(wf * scale)))),
        .h = @max(1, @as(u32, @intFromFloat(@round(hf * scale)))),
    };
}

/// Returns a new image of `w`x`h` (not larger than `src`). Colors are
/// weighted by alpha so transparent pixels do not darken edges.
pub fn resize(gpa: Allocator, src: Image, w: u32, h: u32) Allocator.Error!Image {
    // Horizontal pass into premultiplied floats, then vertical pass.
    const mid = try gpa.alloc(f32, @as(usize, w) * src.height * 4);
    defer gpa.free(mid);
    @memset(mid, 0);
    const sx = @as(f32, @floatFromInt(src.width)) / @as(f32, @floatFromInt(w));
    for (0..src.height) |y| {
        for (0..w) |ox| {
            const acc = mid[(y * w + ox) * 4 ..][0..4];
            span(@as(f32, @floatFromInt(ox)) * sx, sx, src.width, struct {
                fn add(a: *[4]f32, s: Image, yy: usize, x: usize, weight: f32) void {
                    const p = s.pixels[(yy * s.width + x) * 4 ..][0..4];
                    const alpha = @as(f32, @floatFromInt(p[3])) / 255;
                    for (0..3) |c| a[c] += @as(f32, @floatFromInt(p[c])) * alpha * weight;
                    a[3] += alpha * weight;
                }
            }.add, .{ acc, src, y });
        }
    }

    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    const sy = @as(f32, @floatFromInt(src.height)) / @as(f32, @floatFromInt(h));
    for (0..h) |oy| {
        for (0..w) |ox| {
            var acc: [4]f32 = @splat(0);
            span(@as(f32, @floatFromInt(oy)) * sy, sy, src.height, struct {
                fn add(a: *[4]f32, m: []const f32, ww: usize, x: usize, y: usize, weight: f32) void {
                    for (0..4) |c| a[c] += m[(y * ww + x) * 4 + c] * weight;
                }
            }.add, .{ &acc, mid, w, ox });
            const p = out[(oy * w + ox) * 4 ..][0..4];
            const alpha = acc[3] / sy / sx;
            for (0..3) |c| p[c] = if (acc[3] > 0) toByte(acc[c] / acc[3]) else 0;
            p[3] = toByte(alpha * 255);
        }
    }
    return .{ .width = w, .height = h, .pixels = out };
}

/// Calls `f(args..., i, weight)` for every source index covered by
/// [start, start + len), weighting partially covered ends.
fn span(start: f32, len: f32, limit: u32, comptime f: anytype, args: anytype) void {
    const end = start + len;
    var i: usize = @intFromFloat(@floor(start));
    while (i < limit and @as(f32, @floatFromInt(i)) < end) : (i += 1) {
        const lo = @max(start, @as(f32, @floatFromInt(i)));
        const hi = @min(end, @as(f32, @floatFromInt(i + 1)));
        if (hi > lo) @call(.auto, f, args ++ .{ i, hi - lo });
    }
}

fn toByte(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 255)));
}

const testing = std.testing;

test "fit keeps aspect and never enlarges" {
    try testing.expectEqual(@as(u32, 512), fit(1024, 768, .{ .max_dim = 512 }).w);
    try testing.expectEqual(@as(u32, 384), fit(1024, 768, .{ .max_dim = 512 }).h);
    try testing.expectEqual(@as(u32, 100), fit(200, 50, .{ .height = 25 }).w);
    try testing.expectEqual(@as(u32, 200), fit(200, 50, .{ .width = 400 }).w);
}

test "averages areas and respects alpha" {
    const gpa = testing.allocator;
    // 4x2: left half white opaque, right half fully transparent red.
    var px: [4 * 2 * 4]u8 = undefined;
    for (0..2) |y| for (0..4) |x| {
        px[(y * 4 + x) * 4 ..][0..4].* = if (x < 2) .{ 255, 255, 255, 255 } else .{ 255, 0, 0, 0 };
    };
    const out = try resize(gpa, .{ .width = 4, .height = 2, .pixels = &px }, 2, 1);
    defer out.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255, 0, 0, 0, 0 }, out.pixels);

    // 3 -> 2 columns: the middle column is split between both outputs.
    var gray: [3 * 4]u8 = .{ 0, 0, 0, 255, 90, 90, 90, 255, 180, 180, 180, 255 };
    const g = try resize(gpa, .{ .width = 3, .height = 1, .pixels = &gray }, 2, 1);
    defer g.deinit(gpa);
    try testing.expectEqual(@as(u8, 30), g.pixels[0]);
    try testing.expectEqual(@as(u8, 150), g.pixels[4]);
}
