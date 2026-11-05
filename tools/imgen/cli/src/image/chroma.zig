//! Chroma-key removal: turns a flat background color into alpha.
//!
//! Ported from remove_chroma_key.py in OpenAI's Codex imagegen skill
//! (Apache-2.0, https://github.com/openai/codex).
const std = @import("std");
const Allocator = std.mem.Allocator;
const Image = @import("png.zig").Image;

pub const Rgb = [3]u8;

pub const Options = struct {
    /// Null samples the image border.
    key: ?Rgb = null,
    /// Hard mode: channel distance at or below this becomes transparent.
    tolerance: u8 = 12,
    /// Smooth alpha ramp between `transparent_threshold` and `opaque_threshold`.
    soft: bool = true,
    transparent_threshold: f32 = 12,
    opaque_threshold: f32 = 96,
    despill: bool = true,
    /// Shrink the matte by this many pixels (3x3 min filter per pixel).
    contract: u8 = 0,
    /// Gaussian blur radius for the alpha channel.
    feather: f32 = 0,
};

pub const Stats = struct {
    key: Rgb,
    transparent_ratio: f32,
    partial_ratio: f32,
    /// Pixels that matched the key before contract and feather.
    matched: usize,
};

const dominance_threshold = 16.0;
const alpha_noise_floor = 8;

/// Edits `img` in place.
pub fn remove(gpa: Allocator, img: Image, o: Options) Allocator.Error!Stats {
    const key = o.key orelse sampleBorder(img);
    const spill = spillChannels(key);
    var matched: usize = 0;
    const px = img.pixels;
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        const rgb: Rgb = px[i..][0..3].*;
        const d = distance(rgb, key);
        const key_like = d <= 32 or spill.len == 0 or dominance(rgb, spill) >= dominance_threshold;
        var alpha: u32 = if (o.soft and key_like)
            @min(softAlpha(d, o.transparent_threshold, o.opaque_threshold), dominanceAlpha(rgb, key, spill))
        else if (d <= o.tolerance) 0 else 255;
        alpha = (alpha * px[i + 3] + 127) / 255;
        if (alpha <= alpha_noise_floor) alpha = 0;
        if (alpha == 0) {
            px[i..][0..4].* = .{ 0, 0, 0, 0 };
            matched += 1;
            continue;
        }
        if (o.despill and key_like and alpha < 252) despillPixel(px[i..][0..3], spill);
        px[i + 3] = @intCast(alpha);
    }
    for (0..o.contract) |_| try minFilter(gpa, img);
    if (o.feather > 0) try blurAlpha(gpa, img, o.feather);

    var transparent: usize = 0;
    var partial: usize = 0;
    i = 3;
    while (i < px.len) : (i += 4) {
        if (px[i] == 0) transparent += 1 else if (px[i] < 255) partial += 1;
    }
    const total: f32 = @floatFromInt(px.len / 4);
    return .{
        .key = key,
        .transparent_ratio = @as(f32, @floatFromInt(transparent)) / total,
        .partial_ratio = @as(f32, @floatFromInt(partial)) / total,
        .matched = matched,
    };
}

fn distance(a: Rgb, b: Rgb) u8 {
    var m: u8 = 0;
    for (a, b) |x, y| m = @max(m, if (x > y) x - y else y - x);
    return m;
}

fn softAlpha(d: u8, lo: f32, hi: f32) u32 {
    const v: f32 = @floatFromInt(d);
    if (v <= lo) return 0;
    if (v >= hi) return 255;
    const t = (v - lo) / (hi - lo);
    return @intFromFloat(@round(255 * t * t * (3 - 2 * t)));
}

/// Channels that carry the key color, e.g. G for green, R and B for magenta.
const Spill = struct {
    idx: [3]u2 = undefined,
    len: u2 = 0,

    fn has(s: Spill, c: usize) bool {
        for (s.idx[0..s.len]) |i| if (i == c) return true;
        return false;
    }
};

fn spillChannels(key: Rgb) Spill {
    const max = @max(key[0], key[1], key[2]);
    var s: Spill = .{};
    if (max < 128) return s;
    for (key, 0..) |v, c| if (v >= max - 16 and v >= 128) {
        s.idx[s.len] = @intCast(c);
        s.len += 1;
    };
    return s;
}

fn keyStrength(rgb: Rgb, s: Spill) f32 {
    var m: u8 = 255;
    for (s.idx[0..s.len]) |c| m = @min(m, rgb[c]);
    return @floatFromInt(m);
}

fn nonKeyStrength(rgb: Rgb, s: Spill) f32 {
    var m: u8 = 0;
    for (rgb, 0..) |v, c| if (!s.has(c)) {
        m = @max(m, v);
    };
    return @floatFromInt(m);
}

fn dominance(rgb: Rgb, s: Spill) f32 {
    return keyStrength(rgb, s) - nonKeyStrength(rgb, s);
}

fn dominanceAlpha(rgb: Rgb, key: Rgb, s: Spill) u32 {
    if (s.len == 0) return 255;
    const d = dominance(rgb, s);
    if (d <= 0) return 255;
    const key_max: f32 = @floatFromInt(@max(key[0], key[1], key[2]));
    const denom = @max(1, key_max - nonKeyStrength(rgb, s));
    return @intFromFloat(@round((1 - @min(1, d / denom)) * 255));
}

/// Caps the key channels just below the strongest other channel.
fn despillPixel(rgb: *[3]u8, s: Spill) void {
    if (s.len == 0 or s.len == 3) return;
    const cap = @max(0, nonKeyStrength(rgb.*, s) - 1);
    for (s.idx[0..s.len]) |c| {
        if (@as(f32, @floatFromInt(rgb[c])) > cap) rgb[c] = @intFromFloat(cap);
    }
}

/// Per-channel median of a 6-pixel band around the edge.
pub fn sampleBorder(img: Image) Rgb {
    const w = img.width;
    const h = img.height;
    const band = @max(1, @min(w, h, 6));
    const step = @max(1, @min(w, h) / 256);
    var hist: [3][256]u32 = @splat(@splat(0));
    var n: u64 = 0;
    const add = struct {
        fn f(hh: *[3][256]u32, nn: *u64, im: Image, x: u32, y: u32) void {
            const p = im.pixels[(@as(usize, y) * im.width + x) * 4 ..];
            for (0..3) |c| hh[c][p[c]] += 1;
            nn.* += 1;
        }
    }.f;
    var x: u32 = 0;
    while (x < w) : (x += step) {
        for (0..band) |b| {
            add(&hist, &n, img, x, @intCast(b));
            add(&hist, &n, img, x, h - 1 - @as(u32, @intCast(b)));
        }
    }
    var y: u32 = 0;
    while (y < h) : (y += step) {
        for (0..band) |b| {
            add(&hist, &n, img, @intCast(b), y);
            add(&hist, &n, img, w - 1 - @as(u32, @intCast(b)), y);
        }
    }
    var key: Rgb = undefined;
    for (0..3) |c| {
        // Mean of the two middle samples, as statistics.median does.
        const lo = nth(&hist[c], (n - 1) / 2);
        const hi = nth(&hist[c], n / 2);
        key[c] = @intCast((@as(u16, lo) + hi + 1) / 2);
    }
    return key;
}

fn nth(hist: *const [256]u32, k: u64) u8 {
    var seen: u64 = 0;
    for (hist, 0..) |count, v| {
        seen += count;
        if (seen > k) return @intCast(v);
    }
    return 255;
}

fn minFilter(gpa: Allocator, img: Image) Allocator.Error!void {
    const w = img.width;
    const h = img.height;
    const src = try gpa.alloc(u8, @as(usize, w) * h);
    defer gpa.free(src);
    for (src, 0..) |*a, i| a.* = img.pixels[i * 4 + 3];
    for (0..h) |y| for (0..w) |x| {
        var m: u8 = 255;
        for (@max(y, 1) - 1..@min(y + 2, h)) |yy| for (@max(x, 1) - 1..@min(x + 2, w)) |xx| {
            m = @min(m, src[yy * w + xx]);
        };
        img.pixels[(y * w + x) * 4 + 3] = m;
    };
}

/// Separable Gaussian blur of the alpha channel, edges clamped.
fn blurAlpha(gpa: Allocator, img: Image, radius: f32) Allocator.Error!void {
    const r: usize = @intFromFloat(@ceil(radius * 3));
    const kernel = try gpa.alloc(f32, 2 * r + 1);
    defer gpa.free(kernel);
    var sum: f32 = 0;
    for (kernel, 0..) |*k, i| {
        const d: f32 = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(r));
        k.* = @exp(-(d * d) / (2 * radius * radius));
        sum += k.*;
    }
    for (kernel) |*k| k.* /= sum;

    const w = img.width;
    const h = img.height;
    const a = try gpa.alloc(f32, @as(usize, w) * h);
    defer gpa.free(a);
    const tmp = try gpa.alloc(f32, a.len);
    defer gpa.free(tmp);
    for (a, 0..) |*v, i| v.* = @floatFromInt(img.pixels[i * 4 + 3]);
    for (0..h) |y| for (0..w) |x| {
        var acc: f32 = 0;
        for (kernel, 0..) |k, i| {
            const xx = std.math.clamp(@as(isize, @intCast(x + i)) - @as(isize, @intCast(r)), 0, @as(isize, w) - 1);
            acc += k * a[y * w + @as(usize, @intCast(xx))];
        }
        tmp[y * w + x] = acc;
    };
    for (0..h) |y| for (0..w) |x| {
        var acc: f32 = 0;
        for (kernel, 0..) |k, i| {
            const yy = std.math.clamp(@as(isize, @intCast(y + i)) - @as(isize, @intCast(r)), 0, @as(isize, h) - 1);
            acc += k * tmp[@as(usize, @intCast(yy)) * w + x];
        }
        img.pixels[(y * w + x) * 4 + 3] = @intFromFloat(@round(std.math.clamp(acc, 0, 255)));
    };
}

pub fn parseHex(s: []const u8) ?Rgb {
    const hex = if (std.mem.startsWith(u8, s, "#")) s[1..] else s;
    if (hex.len != 6) return null;
    var out: Rgb = undefined;
    for (&out, 0..) |*c, i| c.* = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return null;
    return out;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// 20x20 green with a 10x10 red square in the middle and a 1px blend ring.
fn testImage(gpa: Allocator) !Image {
    const w = 20;
    const px = try gpa.alloc(u8, w * w * 4);
    for (0..w) |y| for (0..w) |x| {
        const inside = x >= 5 and x < 15 and y >= 5 and y < 15;
        const ring = !inside and x >= 4 and x < 16 and y >= 4 and y < 16;
        const c: [4]u8 = if (inside) .{ 220, 30, 30, 255 } else if (ring) .{ 120, 140, 20, 255 } else .{ 0, 255, 0, 255 };
        px[(y * w + x) * 4 ..][0..4].* = c;
    };
    return .{ .width = w, .height = w, .pixels = px };
}

test "removes a green background with soft edges" {
    const gpa = testing.allocator;
    const img = try testImage(gpa);
    defer img.deinit(gpa);
    const s = try remove(gpa, img, .{});
    try testing.expectEqual(Rgb{ 0, 255, 0 }, s.key);
    // 400 - 144 (square + ring) background pixels.
    try testing.expectApproxEqAbs(@as(f32, 256.0 / 400.0), s.transparent_ratio, 0.001);
    const at = struct {
        fn f(im: Image, x: usize, y: usize) [4]u8 {
            return im.pixels[(y * im.width + x) * 4 ..][0..4].*;
        }
    }.f;
    try testing.expectEqual(@as(u8, 255), at(img, 10, 10)[3]);
    try testing.expectEqual(@as(u8, 0), at(img, 0, 0)[3]);
    // The blend ring is greenish: partly transparent and despilled.
    const ring = at(img, 4, 10);
    try testing.expect(ring[3] > 0 and ring[3] < 255);
    try testing.expect(ring[1] <= ring[0]);
}

test "contract and feather" {
    const gpa = testing.allocator;
    const img = try testImage(gpa);
    defer img.deinit(gpa);
    const s = try remove(gpa, img, .{ .contract = 1, .feather = 1 });
    try testing.expect(s.partial_ratio > 0);
    try testing.expect(img.pixels[(10 * 20 + 10) * 4 + 3] > 200);
}

test "explicit key and hard mode" {
    const gpa = testing.allocator;
    const img = try testImage(gpa);
    defer img.deinit(gpa);
    const s = try remove(gpa, img, .{ .key = parseHex("#ff00ff").?, .soft = false });
    try testing.expectEqual(@as(usize, 0), s.matched);
    try testing.expectEqual(@as(?Rgb, .{ 0, 255, 0 }), parseHex("00FF00"));
    try testing.expectEqual(@as(?Rgb, null), parseHex("#0f0"));
}
