//! PNG decode (any color type and bit depth, non-interlaced) to RGBA8, and
//! RGBA8 encode.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const flate = std.compress.flate;

/// 8-bit RGBA pixels, row by row.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(img: Image, gpa: Allocator) void {
        gpa.free(img.pixels);
    }
};

pub const DecodeError = error{
    /// Not a PNG, truncated, or corrupt.
    Invalid,
    /// Adam7 interlacing.
    Interlaced,
} || Allocator.Error;

const signature = "\x89PNG\r\n\x1a\n";
const max_pixels = 1 << 28;

pub fn decode(gpa: Allocator, data: []const u8) DecodeError!Image {
    if (!std.mem.startsWith(u8, data, signature)) return error.Invalid;
    var pos: usize = signature.len;

    var width: u32 = 0;
    var height: u32 = 0;
    var depth: u8 = 0;
    var color: u8 = 0;
    var palette: []const u8 = &.{};
    var trns: []const u8 = &.{};
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);

    while (true) {
        if (pos + 12 > data.len) return error.Invalid;
        const len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const kind = data[pos + 4 ..][0..4];
        if (pos + 12 + len > data.len) return error.Invalid;
        const body = data[pos + 8 ..][0..len];
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13) return error.Invalid;
            width = std.mem.readInt(u32, body[0..4], .big);
            height = std.mem.readInt(u32, body[4..8], .big);
            depth = body[8];
            color = body[9];
            if (body[12] != 0) return error.Interlaced;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            palette = body;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            trns = body;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, body);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }

    const channels: u8 = switch (color) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.Invalid,
    };
    const depth_ok = switch (color) {
        0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
        3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
        else => depth == 8 or depth == 16,
    };
    if (!depth_ok or width == 0 or height == 0) return error.Invalid;
    if (@as(u64, width) * height > max_pixels) return error.Invalid;
    if (color == 3 and palette.len == 0) return error.Invalid;

    const bits_per_pixel: usize = @as(usize, channels) * depth;
    const row_len = (width * bits_per_pixel + 7) / 8;
    const bpp = @max(1, bits_per_pixel / 8);

    // Inflate: one filter byte plus the row, per row.
    const raw = try gpa.alloc(u8, (row_len + 1) * height);
    defer gpa.free(raw);
    {
        var in: std.Io.Reader = .fixed(idat.items);
        var window: [flate.max_window_len]u8 = undefined;
        var z: flate.Decompress = .init(&in, .zlib, &window);
        z.reader.readSliceAll(raw) catch return error.Invalid;
    }

    // Unfilter in place; `prev` is the previous unfiltered row.
    const zero = try gpa.alloc(u8, row_len);
    defer gpa.free(zero);
    @memset(zero, 0);
    var prev: []const u8 = zero;
    for (0..height) |y| {
        const line = raw[y * (row_len + 1) ..][0 .. row_len + 1];
        const row = line[1..];
        try unfilter(line[0], row, prev, bpp);
        prev = row;
    }

    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(pixels);
    for (0..height) |y| {
        const row = raw[y * (row_len + 1) + 1 ..][0..row_len];
        const out = pixels[y * width * 4 ..][0 .. width * 4];
        for (0..width) |x| {
            out[x * 4 ..][0..4].* = pixel(row, x, color, depth, palette, trns);
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

fn unfilter(kind: u8, row: []u8, prev: []const u8, bpp: usize) error{Invalid}!void {
    switch (kind) {
        0 => {},
        1 => for (bpp..row.len) |i| {
            row[i] +%= row[i - bpp];
        },
        2 => for (row, prev) |*c, b| {
            c.* +%= b;
        },
        3 => for (row, 0..) |*c, i| {
            const a: u16 = if (i >= bpp) row[i - bpp] else 0;
            c.* +%= @intCast((a + prev[i]) / 2);
        },
        4 => for (row, 0..) |*c, i| {
            const a: u8 = if (i >= bpp) row[i - bpp] else 0;
            const cc: u8 = if (i >= bpp) prev[i - bpp] else 0;
            c.* +%= paeth(a, prev[i], cc);
        },
        else => return error.Invalid,
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// Sample `i` of a row at `depth` bits, as a raw value.
fn sample(row: []const u8, i: usize, depth: u8) u16 {
    return switch (depth) {
        8 => row[i],
        16 => std.mem.readInt(u16, row[i * 2 ..][0..2], .big),
        else => blk: {
            const bit = i * depth;
            const shift: u3 = @intCast(8 - depth - bit % 8);
            const mask: u8 = (@as(u8, 1) << @intCast(depth)) - 1;
            break :blk (row[bit / 8] >> shift) & mask;
        },
    };
}

/// Scales a `depth`-bit sample to 8 bits.
fn to8(v: u16, depth: u8) u8 {
    return switch (depth) {
        16 => @intCast(v >> 8),
        8 => @intCast(v),
        else => @intCast(v * 255 / ((@as(u16, 1) << @intCast(depth)) - 1)),
    };
}

fn pixel(row: []const u8, x: usize, color: u8, depth: u8, palette: []const u8, trns: []const u8) [4]u8 {
    switch (color) {
        0 => {
            const v = sample(row, x, depth);
            const g = to8(v, depth);
            const transparent = trns.len >= 2 and v == std.mem.readInt(u16, trns[0..2], .big);
            return .{ g, g, g, if (transparent) 0 else 255 };
        },
        2 => {
            const r = sample(row, x * 3, depth);
            const g = sample(row, x * 3 + 1, depth);
            const b = sample(row, x * 3 + 2, depth);
            const transparent = trns.len >= 6 and
                r == std.mem.readInt(u16, trns[0..2], .big) and
                g == std.mem.readInt(u16, trns[2..4], .big) and
                b == std.mem.readInt(u16, trns[4..6], .big);
            return .{ to8(r, depth), to8(g, depth), to8(b, depth), if (transparent) 0 else 255 };
        },
        3 => {
            const i = sample(row, x, depth);
            if (i * 3 + 2 >= palette.len) return .{ 0, 0, 0, 255 };
            const alpha: u8 = if (i < trns.len) trns[i] else 255;
            return .{ palette[i * 3], palette[i * 3 + 1], palette[i * 3 + 2], alpha };
        },
        4 => {
            const g = to8(sample(row, x * 2, depth), depth);
            return .{ g, g, g, to8(sample(row, x * 2 + 1, depth), depth) };
        },
        else => return .{
            to8(sample(row, x * 4, depth), depth),
            to8(sample(row, x * 4 + 1, depth), depth),
            to8(sample(row, x * 4 + 2, depth), depth),
            to8(sample(row, x * 4 + 3, depth), depth),
        },
    }
}

/// Encodes RGBA8 pixels. Each row uses the filter with the smallest sum of
/// absolute values, the usual heuristic.
pub fn encode(gpa: Allocator, img: Image) Allocator.Error![]u8 {
    var out: Writer.Allocating = try .initCapacity(gpa, 64 << 10);
    defer out.deinit();
    write(gpa, &out.writer, img) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn write(gpa: Allocator, w: *Writer, img: Image) !void {
    try w.writeAll(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    try chunk(w, "IHDR", &ihdr);

    var zdata: Writer.Allocating = try .initCapacity(gpa, 64 << 10);
    defer zdata.deinit();
    {
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var z: flate.Compress = try .init(&zdata.writer, window, .zlib, .level_4);
        const stride = @as(usize, img.width) * 4;
        const best = try gpa.alloc(u8, stride);
        defer gpa.free(best);
        const trial = try gpa.alloc(u8, stride);
        defer gpa.free(trial);
        const zero = try gpa.alloc(u8, stride);
        defer gpa.free(zero);
        @memset(zero, 0);
        for (0..img.height) |y| {
            const row = img.pixels[y * stride ..][0..stride];
            const prev = if (y == 0) zero else img.pixels[(y - 1) * stride ..][0..stride];
            var best_kind: u8 = 0;
            var best_score: u64 = std.math.maxInt(u64);
            for (0..5) |k| {
                const kind: u8 = @intCast(k);
                filter(kind, trial, row, prev);
                var score: u64 = 0;
                for (trial) |b| score += @abs(@as(i8, @bitCast(b)));
                if (score < best_score) {
                    best_score = score;
                    best_kind = kind;
                    @memcpy(best, trial);
                }
            }
            try z.writer.writeByte(best_kind);
            try z.writer.writeAll(best);
        }
        try z.finish();
    }
    try chunk(w, "IDAT", zdata.written());
    try chunk(w, "IEND", "");
}

fn filter(kind: u8, out: []u8, row: []const u8, prev: []const u8) void {
    for (out, 0..) |*o, i| {
        const a: u8 = if (i >= 4) row[i - 4] else 0;
        const b = prev[i];
        const c: u8 = if (i >= 4) prev[i - 4] else 0;
        o.* = row[i] -% switch (kind) {
            0 => 0,
            1 => a,
            2 => b,
            3 => @as(u8, @intCast((@as(u16, a) + b) / 2)),
            else => paeth(a, b, c),
        };
    }
}

fn chunk(w: *Writer, kind: *const [4]u8, body: []const u8) Writer.Error!void {
    try w.writeInt(u32, @intCast(body.len), .big);
    try w.writeAll(kind);
    try w.writeAll(body);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(body);
    try w.writeInt(u32, crc.final(), .big);
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// Builds a PNG from already-filtered (filter 0) rows, for decoder tests.
fn rawPng(gpa: Allocator, width: u32, height: u32, depth: u8, color: u8, rows: []const u8, extra: []const struct { kind: *const [4]u8, body: []const u8 }) ![]u8 {
    var out: Writer.Allocating = try .initCapacity(gpa, 1024);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ depth, color, 0, 0, 0 };
    try chunk(w, "IHDR", &ihdr);
    for (extra) |e| try chunk(w, e.kind, e.body);
    var zdata: Writer.Allocating = try .initCapacity(gpa, 1024);
    defer zdata.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var z: flate.Compress = try .init(&zdata.writer, window, .zlib, .default);
    try z.writer.writeAll(rows);
    try z.finish();
    try chunk(w, "IDAT", zdata.written());
    try chunk(w, "IEND", "");
    return out.toOwnedSlice();
}

test "round trip keeps pixels" {
    const gpa = testing.allocator;
    var pixels: [5 * 3 * 4]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast((i * 37) % 256);
    const data = try encode(gpa, .{ .width = 5, .height = 3, .pixels = &pixels });
    defer gpa.free(data);
    const back = try decode(gpa, data);
    defer back.deinit(gpa);
    try testing.expectEqual(@as(u32, 5), back.width);
    try testing.expectEqual(@as(u32, 3), back.height);
    try testing.expectEqualSlices(u8, &pixels, back.pixels);
}

test "decodes gray, rgb, palette and 16-bit" {
    const gpa = testing.allocator;

    // 2x1 gray, 1 bit: black, white.
    const g1 = try rawPng(gpa, 2, 1, 1, 0, &.{ 0, 0b0100_0000 }, &.{});
    defer gpa.free(g1);
    const a = try decode(gpa, g1);
    defer a.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 255, 255, 255, 255 }, a.pixels);

    // 1x1 RGB 16-bit with tRNS matching the color.
    const rgb16 = try rawPng(gpa, 1, 1, 16, 2, &.{ 0, 0x12, 0x34, 0xab, 0xcd, 0xff, 0xff }, &.{
        .{ .kind = "tRNS", .body = &.{ 0x12, 0x34, 0xab, 0xcd, 0xff, 0xff } },
    });
    defer gpa.free(rgb16);
    const b = try decode(gpa, rgb16);
    defer b.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0xab, 0xff, 0 }, b.pixels);

    // 3x1 palette, 2 bits, with alpha for entry 1.
    const pal = try rawPng(gpa, 3, 1, 2, 3, &.{ 0, 0b00_01_10_00 }, &.{
        .{ .kind = "PLTE", .body = &.{ 255, 0, 0, 0, 255, 0, 0, 0, 255 } },
        .{ .kind = "tRNS", .body = &.{ 255, 128 } },
    });
    defer gpa.free(pal);
    const c = try decode(gpa, pal);
    defer c.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255 }, c.pixels);

    // 1x2 gray+alpha 8-bit, second row Up-filtered.
    const ga = try rawPng(gpa, 1, 2, 8, 4, &.{ 0, 100, 200, 2, 10, 10 }, &.{});
    defer gpa.free(ga);
    const d = try decode(gpa, ga);
    defer d.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 100, 100, 100, 200, 110, 110, 110, 210 }, d.pixels);
}

test "rejects interlaced and junk" {
    const gpa = testing.allocator;
    try testing.expectError(error.Invalid, decode(gpa, "nope"));
    var data = try rawPng(gpa, 1, 1, 8, 6, &.{ 0, 1, 2, 3, 4 }, &.{});
    defer gpa.free(data);
    data[signature.len + 8 + 12] = 1; // interlace byte
    try testing.expectError(error.Interlaced, decode(gpa, data));
}
