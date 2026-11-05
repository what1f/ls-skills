//! GIF encode and decode.
//!
//! Encode: RGBA8 frames of one size share a global palette (median cut over
//! a 15-bit color histogram), no dithering. Pixels with alpha below 128
//! become the transparent index.
//!
//! Decode: every frame is composited onto the canvas the way browsers show
//! it (disposal methods, local palettes, interlacing), so each returned frame
//! is a full-canvas RGBA8 image.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Image = @import("png.zig").Image;

pub const EncodeOptions = struct {
    /// Per-frame delay in hundredths of a second, GIF's own unit.
    delay_cs: u16 = 20,
    /// Number of repeats; 0 loops forever.
    loop: u16 = 0,
};

pub const Encoded = struct {
    data: []u8,
    /// Opaque palette entries used.
    colors: usize,
    transparent: bool,
};

const alpha_cutoff = 128;

/// All frames must have the same size, at most 65535 on each side.
pub fn encode(gpa: Allocator, frames: []const Image, o: EncodeOptions) Allocator.Error!Encoded {
    std.debug.assert(frames.len > 0);
    const pal = try Palette.build(gpa, frames);
    defer gpa.free(pal.map);

    var out: Writer.Allocating = try .initCapacity(gpa, 64 << 10);
    defer out.deinit();
    write(gpa, &out.writer, frames, &pal, o) catch return error.OutOfMemory;
    return .{ .data = try out.toOwnedSlice(), .colors = pal.len, .transparent = pal.transparent };
}

fn write(gpa: Allocator, w: *Writer, frames: []const Image, pal: *const Palette, o: EncodeOptions) !void {
    const width: u16 = @intCast(frames[0].width);
    const height: u16 = @intCast(frames[0].height);
    const entries = pal.len + @intFromBool(pal.transparent);
    var bits: u3 = 1; // table holds 2^(bits) entries, bits in 1..8 stored as bits-1
    while ((@as(usize, 1) << (@as(u4, bits) + 1)) < entries) bits += 1;
    const table_bits: u4 = @as(u4, bits) + 1;
    const transparent_index: u8 = if (pal.transparent) @intCast(pal.len) else 0;

    try w.writeAll("GIF89a");
    try w.writeInt(u16, width, .little);
    try w.writeInt(u16, height, .little);
    try w.writeByte(0x80 | (@as(u8, bits) << 4) | bits);
    try w.writeByte(if (pal.transparent) transparent_index else 0);
    try w.writeByte(0);
    for (0..@as(usize, 1) << table_bits) |i| {
        const c: [3]u8 = if (i < pal.len) pal.colors[i] else .{ 0, 0, 0 };
        try w.writeAll(&c);
    }
    if (frames.len > 1) {
        try w.writeAll("\x21\xff\x0bNETSCAPE2.0\x03\x01");
        try w.writeInt(u16, o.loop, .little);
        try w.writeByte(0);
    }

    const indices = try gpa.alloc(u8, @as(usize, width) * height);
    defer gpa.free(indices);
    var lzw: Lzw = try .init(gpa);
    defer lzw.deinit(gpa);
    const min_code: u4 = @max(2, table_bits);
    // Transparent frames must clear before the next one, or old pixels show
    // through; opaque frames simply cover the previous one.
    const disposal: u8 = if (pal.transparent) 2 else 1;
    for (frames) |f| {
        try w.writeAll("\x21\xf9\x04");
        try w.writeByte((disposal << 2) | @intFromBool(pal.transparent));
        try w.writeInt(u16, o.delay_cs, .little);
        try w.writeByte(if (pal.transparent) transparent_index else 0);
        try w.writeByte(0);

        try w.writeByte(0x2c);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, width, .little);
        try w.writeInt(u16, height, .little);
        try w.writeByte(0);

        var i: usize = 0;
        var p: usize = 0;
        while (i < indices.len) : (i += 1) {
            const px = f.pixels[p..][0..4];
            p += 4;
            indices[i] = if (px[3] < alpha_cutoff) transparent_index else pal.map[bucket(px[0..3].*)];
        }
        try w.writeByte(min_code);
        try lzw.encode(w, indices, min_code);
    }
    try w.writeByte(0x3b);
}

fn bucket(c: [3]u8) u15 {
    return (@as(u15, c[0] >> 3) << 10) | (@as(u15, c[1] >> 3) << 5) | (c[2] >> 3);
}

const Palette = struct {
    colors: [256][3]u8,
    len: usize,
    transparent: bool,
    /// 15-bit color bucket to palette index.
    map: []u8,

    const Entry = struct {
        key: u15,
        count: u64,
        mean: [3]u8,
    };

    fn build(gpa: Allocator, frames: []const Image) Allocator.Error!Palette {
        const n_buckets = 1 << 15;
        const counts = try gpa.alloc(u64, n_buckets);
        defer gpa.free(counts);
        const sums = try gpa.alloc([3]u64, n_buckets);
        defer gpa.free(sums);
        @memset(counts, 0);
        @memset(sums, .{ 0, 0, 0 });
        var transparent = false;
        for (frames) |f| {
            var i: usize = 0;
            while (i < f.pixels.len) : (i += 4) {
                const px = f.pixels[i..][0..4];
                if (px[3] < alpha_cutoff) {
                    transparent = true;
                    continue;
                }
                const k = bucket(px[0..3].*);
                counts[k] += 1;
                for (0..3) |c| sums[k][c] += px[c];
            }
        }

        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);
        for (counts, 0..) |n, k| {
            if (n == 0) continue;
            var mean: [3]u8 = undefined;
            for (0..3) |c| mean[c] = @intCast((sums[k][c] + n / 2) / n);
            try entries.append(gpa, .{ .key = @intCast(k), .count = n, .mean = mean });
        }

        var pal: Palette = .{ .colors = undefined, .len = 0, .transparent = transparent, .map = try gpa.alloc(u8, n_buckets) };
        errdefer gpa.free(pal.map);
        @memset(pal.map, 0);
        const max: usize = if (transparent) 255 else 256;
        if (entries.items.len == 0) {
            pal.colors[0] = .{ 0, 0, 0 };
            pal.len = 1;
            return pal;
        }
        if (entries.items.len <= max) {
            for (entries.items, 0..) |e, i| {
                pal.colors[i] = e.mean;
                pal.map[e.key] = @intCast(i);
            }
            pal.len = entries.items.len;
            return pal;
        }

        // Median cut: split the box with the widest channel range weighted by
        // pixel count, at the weighted median along that channel.
        const Box = struct { start: usize, end: usize };
        var boxes: std.ArrayList(Box) = try .initCapacity(gpa, max);
        defer boxes.deinit(gpa);
        boxes.appendAssumeCapacity(.{ .start = 0, .end = entries.items.len });
        while (boxes.items.len < max) {
            var best: ?usize = null;
            var best_score: f64 = 0;
            var best_channel: usize = 0;
            for (boxes.items, 0..) |b, bi| {
                if (b.end - b.start < 2) continue;
                var lo: [3]u8 = .{ 255, 255, 255 };
                var hi: [3]u8 = .{ 0, 0, 0 };
                var total: u64 = 0;
                for (entries.items[b.start..b.end]) |e| {
                    for (0..3) |c| {
                        lo[c] = @min(lo[c], e.mean[c]);
                        hi[c] = @max(hi[c], e.mean[c]);
                    }
                    total += e.count;
                }
                var channel: usize = 0;
                for (1..3) |c| {
                    if (hi[c] - lo[c] > hi[channel] - lo[channel]) channel = c;
                }
                const range = hi[channel] - lo[channel];
                if (range == 0) continue;
                const score = @as(f64, @floatFromInt(range)) * @sqrt(@as(f64, @floatFromInt(total)));
                if (score > best_score) {
                    best_score = score;
                    best = bi;
                    best_channel = channel;
                }
            }
            const bi = best orelse break;
            const b = boxes.items[bi];
            const slice = entries.items[b.start..b.end];
            const Ctx = struct {
                channel: usize,
                fn less(ctx: @This(), x: Entry, y: Entry) bool {
                    return x.mean[ctx.channel] < y.mean[ctx.channel];
                }
            };
            std.mem.sort(Entry, slice, Ctx{ .channel = best_channel }, Ctx.less);
            var total: u64 = 0;
            for (slice) |e| total += e.count;
            var acc: u64 = 0;
            var split: usize = 1;
            for (slice, 0..) |e, i| {
                acc += e.count;
                if (acc * 2 >= total) {
                    split = i + 1;
                    break;
                }
            }
            split = std.math.clamp(split, 1, slice.len - 1);
            boxes.items[bi] = .{ .start = b.start, .end = b.start + split };
            boxes.appendAssumeCapacity(.{ .start = b.start + split, .end = b.end });
        }

        for (boxes.items, 0..) |b, i| {
            var total: u64 = 0;
            var sum: [3]u64 = .{ 0, 0, 0 };
            for (entries.items[b.start..b.end]) |e| {
                total += e.count;
                for (0..3) |c| sum[c] += @as(u64, e.mean[c]) * e.count;
            }
            for (0..3) |c| pal.colors[i][c] = @intCast((sum[c] + total / 2) / total);
        }
        pal.len = boxes.items.len;
        for (entries.items) |e| pal.map[e.key] = nearest(pal.colors[0..pal.len], e.mean);
        return pal;
    }
};

fn nearest(colors: []const [3]u8, c: [3]u8) u8 {
    var best: usize = 0;
    var best_d: u32 = std.math.maxInt(u32);
    for (colors, 0..) |p, i| {
        var d: u32 = 0;
        for (0..3) |k| {
            const diff = @as(i32, p[k]) - c[k];
            d += @intCast(diff * diff);
        }
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return @intCast(best);
}

/// LZW with variable code width, as GIF requires. The string table is an
/// open-addressing hash of (prefix code, next index) pairs.
const Lzw = struct {
    keys: []u32,
    codes: []u16,

    const table_size = 8191;

    fn init(gpa: Allocator) Allocator.Error!Lzw {
        const keys = try gpa.alloc(u32, table_size);
        errdefer gpa.free(keys);
        return .{ .keys = keys, .codes = try gpa.alloc(u16, table_size) };
    }

    fn deinit(l: *Lzw, gpa: Allocator) void {
        gpa.free(l.keys);
        gpa.free(l.codes);
    }

    fn slot(l: *const Lzw, key: u32) usize {
        var h: usize = @intCast((key *% 2654435761) % table_size);
        while (l.keys[h] != 0 and l.keys[h] != key) h = (h + 1) % table_size;
        return h;
    }

    fn encode(l: *Lzw, w: *Writer, indices: []const u8, min_code: u4) Writer.Error!void {
        const clear: u16 = @as(u16, 1) << min_code;
        const eoi = clear + 1;
        var bw: BitWriter = .{ .w = w };
        var size: u4 = min_code + 1;
        var max_code: u16 = eoi;
        @memset(l.keys, 0);
        try bw.put(clear, size);
        var cur: u16 = indices[0];
        for (indices[1..]) |c| {
            // +1 keeps 0 free as the empty marker.
            const key = ((@as(u32, cur) << 8) | c) + 1;
            const s = l.slot(key);
            if (l.keys[s] == key) {
                cur = l.codes[s];
                continue;
            }
            try bw.put(cur, size);
            max_code += 1;
            l.keys[s] = key;
            l.codes[s] = max_code;
            if (max_code >= (@as(u16, 1) << size)) size += 1;
            if (max_code == 4095) {
                try bw.put(clear, size);
                @memset(l.keys, 0);
                size = min_code + 1;
                max_code = eoi;
            }
            cur = c;
        }
        try bw.put(cur, size);
        // The decoder adds one more entry after reading `cur` and may widen.
        if (max_code + 1 >= (@as(u16, 1) << size) and size < 12) size += 1;
        try bw.put(eoi, size);
        try bw.finish();
    }
};

/// Packs codes LSB first into 255-byte sub-blocks.
const BitWriter = struct {
    w: *Writer,
    acc: u32 = 0,
    bits: u5 = 0,
    block: [255]u8 = undefined,
    len: u8 = 0,

    fn put(b: *BitWriter, code: u16, size: u4) Writer.Error!void {
        b.acc |= @as(u32, code) << b.bits;
        var bits: u6 = @as(u6, b.bits) + size;
        while (bits >= 8) : (bits -= 8) {
            try b.byte(@truncate(b.acc));
            b.acc >>= 8;
        }
        b.bits = @intCast(bits);
    }

    fn byte(b: *BitWriter, v: u8) Writer.Error!void {
        b.block[b.len] = v;
        b.len += 1;
        if (b.len == 255) try b.flushBlock();
    }

    fn flushBlock(b: *BitWriter) Writer.Error!void {
        if (b.len == 0) return;
        try b.w.writeByte(b.len);
        try b.w.writeAll(b.block[0..b.len]);
        b.len = 0;
    }

    fn finish(b: *BitWriter) Writer.Error!void {
        if (b.bits > 0) try b.byte(@truncate(b.acc));
        b.acc = 0;
        b.bits = 0;
        try b.flushBlock();
        try b.w.writeByte(0);
    }
};

// ---------------------------------------------------------------------------
// Decode

pub const Decoded = struct {
    width: u32,
    height: u32,
    frames: []Image,
    /// Per-frame delay in hundredths of a second, as stored.
    delays_cs: []u16,

    pub fn deinit(d: Decoded, gpa: Allocator) void {
        for (d.frames) |f| f.deinit(gpa);
        gpa.free(d.frames);
        gpa.free(d.delays_cs);
    }
};

pub const DecodeError = error{
    /// Not a GIF, truncated, or corrupt.
    Invalid,
    /// More pixels than we are willing to hold in memory.
    TooLarge,
} || Allocator.Error;

pub fn isGif(data: []const u8) bool {
    return std.mem.startsWith(u8, data, "GIF87a") or std.mem.startsWith(u8, data, "GIF89a");
}

const max_total_pixels = 1 << 26;

pub fn decode(gpa: Allocator, data: []const u8) DecodeError!Decoded {
    if (!isGif(data) or data.len < 13) return error.Invalid;
    var r: Reader = .{ .data = data, .pos = 6 };
    const width: u32 = try r.u16le();
    const height: u32 = try r.u16le();
    const packed_lsd = try r.byte();
    _ = try r.byte(); // background index: browsers show transparent instead
    _ = try r.byte();
    if (width == 0 or height == 0) return error.Invalid;
    const canvas_px = @as(usize, width) * height;
    if (canvas_px > max_total_pixels) return error.TooLarge;
    var global: []const u8 = &.{};
    if (packed_lsd & 0x80 != 0) global = try r.take(3 * (@as(usize, 2) << @as(u3, @intCast(packed_lsd & 7))));

    const canvas = try gpa.alloc(u8, canvas_px * 4);
    defer gpa.free(canvas);
    @memset(canvas, 0);
    const saved = try gpa.alloc(u8, canvas_px * 4);
    defer gpa.free(saved);

    var frames: std.ArrayList(Image) = .empty;
    errdefer {
        for (frames.items) |f| f.deinit(gpa);
        frames.deinit(gpa);
    }
    var delays: std.ArrayList(u16) = .empty;
    errdefer delays.deinit(gpa);
    var lzw_data: std.ArrayList(u8) = .empty;
    defer lzw_data.deinit(gpa);
    var indices: std.ArrayList(u8) = .empty;
    defer indices.deinit(gpa);

    var disposal: u8 = 0;
    var delay: u16 = 0;
    var transparent: ?u8 = null;
    while (true) {
        const kind = r.byte() catch break; // tolerate a missing trailer
        switch (kind) {
            0x3b => break,
            0x21 => {
                const label = try r.byte();
                if (label == 0xf9) {
                    const n = try r.byte();
                    const body = try r.take(n);
                    if (n >= 4) {
                        disposal = (body[0] >> 2) & 7;
                        delay = std.mem.readInt(u16, body[1..3], .little);
                        transparent = if (body[0] & 1 != 0) body[3] else null;
                    }
                }
                try r.skipBlocks();
            },
            0x2c => {
                const left: u32 = try r.u16le();
                const top: u32 = try r.u16le();
                const fw: u32 = try r.u16le();
                const fh: u32 = try r.u16le();
                const packed_id = try r.byte();
                var palette = global;
                if (packed_id & 0x80 != 0) palette = try r.take(3 * (@as(usize, 2) << @as(u3, @intCast(packed_id & 7))));
                const interlaced = packed_id & 0x40 != 0;
                const min_code = try r.byte();
                if (min_code < 2 or min_code > 11) return error.Invalid;
                lzw_data.clearRetainingCapacity();
                try r.readBlocks(gpa, &lzw_data);

                if ((frames.items.len + 1) * canvas_px > max_total_pixels) return error.TooLarge;
                const n = @as(usize, fw) * fh;
                try indices.resize(gpa, n);
                lzwDecode(lzw_data.items, @intCast(min_code), indices.items);

                if (disposal == 3) @memcpy(saved, canvas);
                for (0..fh) |row| {
                    const y = top + @as(u32, @intCast(interlacedRow(row, fh, interlaced)));
                    if (y >= height) continue;
                    for (0..fw) |col| {
                        const x = left + @as(u32, @intCast(col));
                        if (x >= width) continue;
                        const raw = indices.items[row * fw + col];
                        if (transparent != null and raw == transparent.?) continue;
                        const idx: usize = raw;
                        if (idx * 3 + 3 > palette.len) continue;
                        const dst = canvas[(@as(usize, y) * width + x) * 4 ..][0..4];
                        dst.* = .{ palette[idx * 3], palette[idx * 3 + 1], palette[idx * 3 + 2], 255 };
                    }
                }
                try frames.append(gpa, .{ .width = width, .height = height, .pixels = try gpa.dupe(u8, canvas) });
                try delays.append(gpa, delay);

                switch (disposal) {
                    2 => for (0..fh) |row| {
                        const y = top + @as(u32, @intCast(row));
                        if (y >= height) continue;
                        const x0 = @min(left, width);
                        const x1 = @min(left + fw, width);
                        @memset(canvas[(@as(usize, y) * width + x0) * 4 .. (@as(usize, y) * width + x1) * 4], 0);
                    },
                    3 => @memcpy(canvas, saved),
                    else => {},
                }
                disposal = 0;
                delay = 0;
                transparent = null;
            },
            else => return error.Invalid,
        }
    }
    if (frames.items.len == 0) return error.Invalid;
    const out_delays = try delays.toOwnedSlice(gpa);
    errdefer gpa.free(out_delays);
    return .{ .width = width, .height = height, .frames = try frames.toOwnedSlice(gpa), .delays_cs = out_delays };
}

/// Row `i` of the stored data maps to this image row.
fn interlacedRow(i: usize, h: usize, interlaced: bool) usize {
    if (!interlaced) return i;
    const passes = [_]struct { start: usize, step: usize }{ .{ .start = 0, .step = 8 }, .{ .start = 4, .step = 8 }, .{ .start = 2, .step = 4 }, .{ .start = 1, .step = 2 } };
    var left = i;
    for (passes) |p| {
        const count = if (h > p.start) (h - p.start + p.step - 1) / p.step else 0;
        if (left < count) return p.start + left * p.step;
        left -= count;
    }
    return i;
}

/// Fills `out` with color indices; a short stream leaves index 0.
fn lzwDecode(data: []const u8, min_code: u4, out: []u8) void {
    @memset(out, 0);
    const clear: u16 = @as(u16, 1) << min_code;
    const eoi = clear + 1;
    var prefix: [4096]u16 = undefined;
    var suffix: [4096]u8 = undefined;
    var stack: [4097]u8 = undefined;
    for (0..clear) |i| suffix[i] = @truncate(i);
    var size: u4 = min_code + 1;
    var next: u16 = clear + 2;
    var prev: ?u16 = null;
    var first: u8 = 0;
    var pos: usize = 0;
    var bit: usize = 0;
    var written: usize = 0;
    while (written < out.len) {
        // Read `size` bits LSB first.
        if (bit + size > data.len * 8) break;
        var code: u16 = 0;
        for (0..size) |k| {
            const b = bit + k;
            if ((data[b / 8] >> @as(u3, @intCast(b % 8))) & 1 != 0) code |= @as(u16, 1) << @as(u4, @intCast(k));
        }
        bit += size;
        _ = &pos;

        if (code == clear) {
            size = min_code + 1;
            next = clear + 2;
            prev = null;
            continue;
        }
        if (code == eoi) break;
        const p = prev orelse {
            if (code >= clear) break;
            first = @intCast(code);
            out[written] = first;
            written += 1;
            prev = code;
            continue;
        };
        if (code > next) break;
        var sp: usize = 0;
        var c: u16 = code;
        if (code == next) {
            stack[sp] = first;
            sp += 1;
            c = p;
        }
        while (c >= clear) {
            if (c == eoi or sp >= 4096) return;
            stack[sp] = suffix[c];
            sp += 1;
            c = prefix[c];
        }
        first = @intCast(c);
        stack[sp] = first;
        sp += 1;
        while (sp > 0 and written < out.len) {
            sp -= 1;
            out[written] = stack[sp];
            written += 1;
        }
        if (next < 4096) {
            prefix[next] = p;
            suffix[next] = first;
            next += 1;
            if (next == (@as(u16, 1) << size) and size < 12) size += 1;
        }
        prev = code;
    }
}

const Reader = struct {
    data: []const u8,
    pos: usize,

    fn byte(r: *Reader) error{Invalid}!u8 {
        if (r.pos >= r.data.len) return error.Invalid;
        r.pos += 1;
        return r.data[r.pos - 1];
    }

    fn u16le(r: *Reader) error{Invalid}!u16 {
        const b = try r.take(2);
        return std.mem.readInt(u16, b[0..2], .little);
    }

    fn take(r: *Reader, n: usize) error{Invalid}![]const u8 {
        if (r.pos + n > r.data.len) return error.Invalid;
        r.pos += n;
        return r.data[r.pos - n .. r.pos];
    }

    fn skipBlocks(r: *Reader) error{Invalid}!void {
        while (true) {
            const n = try r.byte();
            if (n == 0) return;
            _ = try r.take(n);
        }
    }

    fn readBlocks(r: *Reader, gpa: Allocator, out: *std.ArrayList(u8)) (error{Invalid} || Allocator.Error)!void {
        while (true) {
            const n = try r.byte();
            if (n == 0) return;
            try out.appendSlice(gpa, try r.take(n));
        }
    }
};
