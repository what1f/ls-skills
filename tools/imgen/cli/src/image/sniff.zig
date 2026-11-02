//! Reads an image's format and dimensions from its header, without decoding.
const std = @import("std");

pub const Format = enum {
    png,
    jpeg,
    webp,

    pub fn ext(f: Format) []const u8 {
        return switch (f) {
            .png => ".png",
            .jpeg => ".jpg",
            .webp => ".webp",
        };
    }

    pub fn mime(f: Format) []const u8 {
        return switch (f) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
        };
    }

    /// Accepts the names used by `--output-format`.
    pub fn parse(s: []const u8) ?Format {
        if (std.mem.eql(u8, s, "jpg")) return .jpeg;
        return std.meta.stringToEnum(Format, s);
    }

    pub fn fromExt(path: []const u8) ?Format {
        const e = std.fs.path.extension(path);
        if (e.len < 2) return null;
        var buf: [5]u8 = undefined;
        if (e.len - 1 > buf.len) return null;
        return parse(std.ascii.lowerString(&buf, e[1..]));
    }
};

pub const Info = struct {
    format: Format,
    width: u32,
    height: u32,
    /// PNG only: the image has an alpha channel (color type 4 or 6, or tRNS).
    alpha: bool = false,
};

pub fn sniff(data: []const u8) ?Info {
    if (std.mem.startsWith(u8, data, "\x89PNG\r\n\x1a\n")) return png(data);
    if (std.mem.startsWith(u8, data, "\xff\xd8")) return jpeg(data);
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP")) return webp(data);
    return null;
}

fn png(data: []const u8) ?Info {
    if (data.len < 33 or !std.mem.eql(u8, data[12..16], "IHDR")) return null;
    const color_type = data[25];
    var alpha = color_type == 4 or color_type == 6;
    // A tRNS chunk before IDAT also gives the image transparency.
    var pos: usize = 33;
    while (!alpha and pos + 8 <= data.len) {
        const len = std.mem.readInt(u32, data[pos..][0..4], .big);
        const kind = data[pos + 4 ..][0..4];
        if (std.mem.eql(u8, kind, "tRNS")) alpha = true;
        if (std.mem.eql(u8, kind, "IDAT")) break;
        pos += 12 + @as(usize, len);
    }
    return .{
        .format = .png,
        .width = std.mem.readInt(u32, data[16..20], .big),
        .height = std.mem.readInt(u32, data[20..24], .big),
        .alpha = alpha,
    };
}

fn jpeg(data: []const u8) ?Info {
    var pos: usize = 2;
    while (pos + 4 <= data.len) {
        if (data[pos] != 0xff) return null;
        const marker = data[pos + 1];
        if (marker == 0xff) {
            pos += 1;
            continue;
        }
        if (marker == 0xd8 or marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7)) {
            pos += 2;
            continue;
        }
        const len = std.mem.readInt(u16, data[pos + 2 ..][0..2], .big);
        const is_sof = marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
        if (is_sof) {
            if (pos + 9 > data.len) return null;
            return .{
                .format = .jpeg,
                .height = std.mem.readInt(u16, data[pos + 5 ..][0..2], .big),
                .width = std.mem.readInt(u16, data[pos + 7 ..][0..2], .big),
            };
        }
        pos += 2 + @as(usize, len);
    }
    return null;
}

fn webp(data: []const u8) ?Info {
    if (data.len < 30) return null;
    const chunk = data[12..16];
    if (std.mem.eql(u8, chunk, "VP8 ")) {
        return .{
            .format = .webp,
            .width = std.mem.readInt(u16, data[26..28], .little) & 0x3fff,
            .height = std.mem.readInt(u16, data[28..30], .little) & 0x3fff,
        };
    }
    if (std.mem.eql(u8, chunk, "VP8L")) {
        const b = std.mem.readInt(u32, data[21..25], .little);
        return .{ .format = .webp, .width = (b & 0x3fff) + 1, .height = ((b >> 14) & 0x3fff) + 1 };
    }
    if (std.mem.eql(u8, chunk, "VP8X")) {
        return .{
            .format = .webp,
            .width = (std.mem.readInt(u24, data[24..27], .little)) + 1,
            .height = (std.mem.readInt(u24, data[27..30], .little)) + 1,
            .alpha = data[20] & 0x10 != 0,
        };
    }
    return null;
}

test "png" {
    const data = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x04\xe6\x00\x00\x02\x00\x08\x06\x00\x00\x00\x00\x00\x00\x00";
    const info = sniff(data).?;
    try std.testing.expectEqual(Format.png, info.format);
    try std.testing.expectEqual(@as(u32, 1254), info.width);
    try std.testing.expectEqual(@as(u32, 512), info.height);
    try std.testing.expect(info.alpha);
}

test "jpeg" {
    const data = "\xff\xd8\xff\xe0\x00\x04ab\xff\xc0\x00\x11\x08\x01\x00\x02\x00\x03";
    const info = sniff(data).?;
    try std.testing.expectEqual(Format.jpeg, info.format);
    try std.testing.expectEqual(@as(u32, 512), info.width);
    try std.testing.expectEqual(@as(u32, 256), info.height);
}

test "webp lossless" {
    var data: [30]u8 = @splat(0);
    @memcpy(data[0..4], "RIFF");
    @memcpy(data[8..16], "WEBPVP8L");
    // width-1 = 99, height-1 = 49
    std.mem.writeInt(u32, data[21..25], 99 | (49 << 14), .little);
    const info = sniff(&data).?;
    try std.testing.expectEqual(@as(u32, 100), info.width);
    try std.testing.expectEqual(@as(u32, 50), info.height);
}

test "format ext" {
    try std.testing.expectEqual(Format.jpeg, Format.fromExt("a/b.JPG").?);
    try std.testing.expectEqual(null, Format.fromExt("a/b"));
}
