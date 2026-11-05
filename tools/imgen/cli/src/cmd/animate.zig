//! `imgen animate`: sprite sheet PNG to animated GIF, no network.
const std = @import("std");
const clikit = @import("clikit");
const Ctx = @import("../ctx.zig").Ctx;
const png = @import("../image/png.zig");
const gif = @import("../image/gif.zig");
const chroma = @import("../image/chroma.zig");
const resize = @import("../image/resize.zig");
const output = @import("../output.zig");
const local = @import("local.zig");
const cutout = @import("cutout.zig");
const Image = png.Image;

pub const usage =
    \\Turn a sprite sheet into an animated GIF. Runs locally.
    \\
    \\Cells are read left to right, then top to bottom.
    \\
    \\Usage:
    \\  imgen animate --image SHEET.png --grid COLSxROWS --out OUT.gif [flags]
    \\
    \\Flags:
    \\  --image PATH            Sprite sheet PNG
    \\  --grid COLSxROWS        Cell layout, e.g. 3x2
    \\  --out PATH              Output GIF
    \\  --frames N              Use only the first N cells (default all)
    \\  --frame-ms N            Time per frame in ms, 20-60000 (default 200)
    \\  --loop N                Times to repeat; 0 loops forever (default 0)
    \\  --max-dim N             Shrink each frame so its longest edge is N
    \\  --inset N               Trim N px from every cell edge, for grid lines or bleed (default 0)
    \\  --align none|bottom|center
    \\                          Line up the subject across frames: bottom keeps feet on
    \\                          one baseline, center keeps the middle still (default none)
    \\  --transparent           Remove the flat background color
    \\  --key auto|#RRGGBB      Background color; auto samples the sheet border (default auto)
    \\  --force                 Overwrite --out
    \\  --format text|json      Output format (default text)
    \\
;

const Align = enum { none, bottom, center };

pub fn run(ctx: Ctx, args: []const [:0]const u8) !u8 {
    const a = ctx.arena;
    const gpa = ctx.gpa;
    var image: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var grid: ?[2]u32 = null;
    var frames_opt: ?u32 = null;
    var frame_ms: u32 = 200;
    var loop: u16 = 0;
    var max_dim: ?u32 = null;
    var inset: u32 = 0;
    var alignment: Align = .none;
    var transparent = false;
    var key: ?chroma.Rgb = null;
    var force = false;
    var format: clikit.Format = .text;
    const fail = struct {
        fn f(c: Ctx, fmt: clikit.Format, message: []const u8) !u8 {
            return clikit.fail(c.stdout, c.stderr, fmt, .{ .code = "usage", .message = message }, clikit.exit.usage);
        }
    }.f;
    const scanned = clikit.scanFormat(args);

    var it: clikit.ArgIterator = .{ .args = args };
    while (it.next()) |arg| {
        if (clikit.isHelp(arg)) {
            try ctx.stdout.writeAll(usage);
            return clikit.exit.ok;
        }
        const eql = std.mem.eql;
        if (eql(u8, arg, "--transparent")) {
            transparent = true;
        } else if (eql(u8, arg, "--force")) {
            force = true;
        } else inline for (.{ "--image", "--out", "--grid", "--frames", "--frame-ms", "--loop", "--max-dim", "--inset", "--align", "--key", "--format" }) |flag| {
            if (it.value(arg, flag) catch return fail(ctx, scanned, flag ++ " needs a value")) |v| {
                if (comptime eql(u8, flag, "--image")) image = v;
                if (comptime eql(u8, flag, "--out")) out = v;
                if (comptime eql(u8, flag, "--grid")) grid = parseGrid(v) orelse return fail(ctx, scanned, "--grid must look like 3x2 (columns x rows)");
                if (comptime eql(u8, flag, "--frames")) {
                    frames_opt = std.fmt.parseInt(u32, v, 10) catch 0;
                    if (frames_opt.? == 0) return fail(ctx, scanned, "--frames must be a positive number");
                }
                if (comptime eql(u8, flag, "--frame-ms")) {
                    frame_ms = std.fmt.parseInt(u32, v, 10) catch 0;
                    if (frame_ms < 20 or frame_ms > 60000) return fail(ctx, scanned, "--frame-ms must be 20-60000");
                }
                if (comptime eql(u8, flag, "--loop")) loop = std.fmt.parseInt(u16, v, 10) catch return fail(ctx, scanned, "--loop must be 0-65535");
                if (comptime eql(u8, flag, "--max-dim")) {
                    max_dim = std.fmt.parseInt(u32, v, 10) catch 0;
                    if (max_dim.? == 0) return fail(ctx, scanned, "--max-dim must be a positive number");
                }
                if (comptime eql(u8, flag, "--inset")) inset = std.fmt.parseInt(u32, v, 10) catch return fail(ctx, scanned, "--inset must be a number");
                if (comptime eql(u8, flag, "--align")) alignment = std.meta.stringToEnum(Align, v) orelse return fail(ctx, scanned, "--align must be none, bottom or center");
                if (comptime eql(u8, flag, "--key")) {
                    if (!eql(u8, v, "auto")) key = chroma.parseHex(v) orelse return fail(ctx, scanned, "--key must be auto or a color like #00ff00");
                }
                if (comptime eql(u8, flag, "--format")) format = clikit.Format.parse(v) orelse return fail(ctx, .text, "--format must be text or json");
                break;
            }
        } else return fail(ctx, scanned, try std.fmt.allocPrint(a, "unknown argument \"{s}\" (see --help)", .{arg}));
    }
    const in_path = image orelse return fail(ctx, format, "--image is required");
    const g = grid orelse return fail(ctx, format, "--grid is required, e.g. --grid 3x2");
    const out_path = out orelse return fail(ctx, format, "--out is required");
    const cells = g[0] * g[1];
    const n = frames_opt orelse cells;
    if (n > cells) return fail(ctx, format, try std.fmt.allocPrint(a, "--frames {d} is more than the {d} cells in a {d}x{d} grid", .{ n, cells, g[0], g[1] }));
    if (!std.ascii.endsWithIgnoreCase(out_path, ".gif")) return fail(ctx, format, "--out must end in .gif");
    if (!force and output.fileExists(ctx.io, out_path)) return clikit.fail(ctx.stdout, ctx.stderr, format, .{ .code = "exists", .message = try std.fmt.allocPrint(a, "{s} already exists (use --force to overwrite)", .{out_path}) }, clikit.exit.usage);

    const sheet = switch (try local.load(ctx, in_path)) {
        .image => |i| i,
        .fail => |f| return clikit.fail(ctx.stdout, ctx.stderr, format, f, local.exitFor(f)),
    };
    defer sheet.deinit(gpa);
    const cell_w = sheet.width / g[0];
    const cell_h = sheet.height / g[1];
    if (cell_w <= 2 * inset or cell_h <= 2 * inset) return fail(ctx, format, try std.fmt.allocPrint(a, "{d}x{d} cells of {d}x{d} px leave nothing after --inset {d}", .{ g[0], g[1], cell_w, cell_h, inset }));

    var warnings: std.ArrayList([]const u8) = .empty;
    if (sheet.width % g[0] != 0 or sheet.height % g[1] != 0)
        try warnings.append(a, try std.fmt.allocPrint(a, "{d}x{d} px does not split evenly into {d}x{d}; cells were trimmed to {d}x{d}", .{ sheet.width, sheet.height, g[0], g[1], cell_w, cell_h }));

    if (key != null and !transparent) return fail(ctx, format, "--key only applies with --transparent");
    const bg = key orelse chroma.sampleBorder(sheet);
    if (transparent) _ = try chroma.remove(gpa, sheet, .{ .key = bg });

    const fw = cell_w - 2 * inset;
    const fh = cell_h - 2 * inset;
    const frames = try a.alloc(Image, n);
    var made: usize = 0;
    defer for (frames[0..made]) |f| f.deinit(gpa);
    for (0..n) |i| {
        const col: u32 = @intCast(i % g[0]);
        const row: u32 = @intCast(i / g[0]);
        // Spread any remainder pixels, so cell i starts at i*W/cols.
        const x0 = col * sheet.width / g[0] + inset;
        const y0 = row * sheet.height / g[1] + inset;
        frames[i] = try crop(gpa, sheet, x0, y0, fw, fh);
        made += 1;
    }

    // A sheet generated with a transparent background already has alpha.
    const has_alpha = transparent or hasTransparency(sheet);
    const fill: [4]u8 = if (has_alpha) .{ 0, 0, 0, 0 } else .{ bg[0], bg[1], bg[2], 255 };
    const subject = Subject{ .transparent = has_alpha, .bg = bg };
    var clipped: usize = 0;
    for (frames, 0..) |f, i| {
        const b = subject.box(f) orelse {
            try warnings.append(a, try std.fmt.allocPrint(a, "frame {d} looks empty; check --grid and --frames", .{i + 1}));
            continue;
        };
        if (b.x0 == 0 or b.y0 == 0 or b.x1 == f.width - 1 or b.y1 == f.height - 1) clipped += 1;
    }
    // A wrong grid cuts subjects apart, so most cells touch an edge.
    if (clipped * 2 > n) try warnings.append(a, try std.fmt.allocPrint(a, "the subject touches the cell edge in {d} of {d} frames; check --grid, or trim grid lines with --inset", .{ clipped, n }));
    if (alignment != .none) try alignFrames(gpa, frames, subject, alignment, fill);

    if (max_dim) |m| {
        const size = resize.fit(fw, fh, .{ .max_dim = m });
        if (size.w != fw or size.h != fh) {
            for (frames) |*f| {
                const small = try resize.resize(gpa, f.*, size.w, size.h);
                f.deinit(gpa);
                f.* = small;
            }
        }
    }
    if (frames[0].width > 65535 or frames[0].height > 65535) return fail(ctx, format, "frames are larger than GIF allows; use --max-dim");

    const delay_cs: u16 = @intCast((frame_ms + 5) / 10);
    const encoded = try gif.encode(gpa, frames, .{ .delay_cs = delay_cs, .loop = loop });
    defer gpa.free(encoded.data);
    if (output.writeFile(ctx.io, out_path, encoded.data, force)) |f| return clikit.fail(ctx.stdout, ctx.stderr, format, f, local.exitFor(f));

    const data = .{
        .path = out_path,
        .frames = n,
        .grid = try std.fmt.allocPrint(a, "{d}x{d}", .{ g[0], g[1] }),
        .frame_width = frames[0].width,
        .frame_height = frames[0].height,
        .frame_ms = @as(u32, delay_cs) * 10,
        .duration_ms = @as(u32, delay_cs) * 10 * n,
        .colors = encoded.colors,
        .transparent = encoded.transparent,
        .key_color = if (transparent) try cutout.hex(a, bg) else null,
        .bytes = encoded.data.len,
        .warnings = warnings.items,
    };
    switch (format) {
        .json => try clikit.writeOk(ctx.stdout, data),
        .text => {
            for (warnings.items) |w| try ctx.stderr.print("warning: {s}\n", .{w});
            try ctx.stdout.print("{s}\n", .{out_path});
        },
    }
    return clikit.exit.ok;
}

fn hasTransparency(img: Image) bool {
    var i: usize = 3;
    while (i < img.pixels.len) : (i += 4) if (img.pixels[i] < 128) return true;
    return false;
}

fn parseGrid(s: []const u8) ?[2]u32 {
    const x = std.mem.indexOfAny(u8, s, "xX*") orelse return null;
    const c = std.fmt.parseInt(u32, s[0..x], 10) catch return null;
    const r = std.fmt.parseInt(u32, s[x + 1 ..], 10) catch return null;
    if (c == 0 or r == 0 or c * r > 256) return null;
    return .{ c, r };
}

fn crop(gpa: std.mem.Allocator, src: Image, x0: u32, y0: u32, w: u32, h: u32) !Image {
    const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
    for (0..h) |y| {
        const from = ((y0 + y) * src.width + x0) * 4;
        @memcpy(px[y * w * 4 ..][0 .. w * 4], src.pixels[from..][0 .. w * 4]);
    }
    return .{ .width = w, .height = h, .pixels = px };
}

/// Which pixels belong to the drawn subject rather than the background.
const Subject = struct {
    transparent: bool,
    bg: chroma.Rgb,

    const threshold = 48;

    fn is(s: Subject, p: *const [4]u8) bool {
        if (s.transparent) return p[3] >= 128;
        var d: u8 = 0;
        for (0..3) |c| d = @max(d, if (p[c] > s.bg[c]) p[c] - s.bg[c] else s.bg[c] - p[c]);
        return d > threshold;
    }

    const Box = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

    fn box(s: Subject, f: Image) ?Box {
        var b: Box = .{ .x0 = f.width, .y0 = f.height, .x1 = 0, .y1 = 0 };
        var any = false;
        for (0..f.height) |y| for (0..f.width) |x| {
            if (!s.is(f.pixels[(y * f.width + x) * 4 ..][0..4])) continue;
            any = true;
            b.x0 = @min(b.x0, @as(u32, @intCast(x)));
            b.y0 = @min(b.y0, @as(u32, @intCast(y)));
            b.x1 = @max(b.x1, @as(u32, @intCast(x)));
            b.y1 = @max(b.y1, @as(u32, @intCast(y)));
        };
        return if (any) b else null;
    }

    /// Point to hold still: for `bottom`, the lowest subject row and the
    /// horizontal center of the bottom 15% (the feet); for `center`, the
    /// center of mass.
    fn anchor(s: Subject, f: Image, mode: Align) ?[2]f64 {
        const b = s.box(f) orelse return null;
        const y_from: u32 = if (mode == .bottom) b.y1 - (b.y1 - b.y0) * 15 / 100 else b.y0;
        var sx: f64 = 0;
        var sy: f64 = 0;
        var count: f64 = 0;
        for (y_from..b.y1 + 1) |y| for (b.x0..b.x1 + 1) |x| {
            if (!s.is(f.pixels[(y * f.width + x) * 4 ..][0..4])) continue;
            sx += @floatFromInt(x);
            sy += @floatFromInt(y);
            count += 1;
        };
        return .{ sx / count, if (mode == .bottom) @floatFromInt(b.y1) else sy / count };
    }
};

/// Shifts each frame so its anchor lands on the median anchor of all frames.
fn alignFrames(gpa: std.mem.Allocator, frames: []Image, s: Subject, mode: Align, fill: [4]u8) !void {
    const anchors = try gpa.alloc(?[2]f64, frames.len);
    defer gpa.free(anchors);
    var xs: std.ArrayList(f64) = .empty;
    defer xs.deinit(gpa);
    var ys: std.ArrayList(f64) = .empty;
    defer ys.deinit(gpa);
    for (frames, anchors) |f, *an| {
        an.* = s.anchor(f, mode);
        if (an.*) |p| {
            try xs.append(gpa, p[0]);
            try ys.append(gpa, p[1]);
        }
    }
    if (xs.items.len == 0) return;
    const target: [2]f64 = .{ median(xs.items), median(ys.items) };
    for (frames, anchors) |*f, an| {
        const p = an orelse continue;
        const dx: i64 = @intFromFloat(@round(target[0] - p[0]));
        const dy: i64 = @intFromFloat(@round(target[1] - p[1]));
        if (dx == 0 and dy == 0) continue;
        try shift(gpa, f, dx, dy, fill);
    }
}

fn median(v: []f64) f64 {
    std.mem.sort(f64, v, {}, std.sort.asc(f64));
    const m = v.len / 2;
    return if (v.len % 2 == 1) v[m] else (v[m - 1] + v[m]) / 2;
}

fn shift(gpa: std.mem.Allocator, f: *Image, dx: i64, dy: i64, fill: [4]u8) !void {
    const px = try gpa.alloc(u8, f.pixels.len);
    const w: i64 = f.width;
    const h: i64 = f.height;
    for (0..f.height) |yy| for (0..f.width) |xx| {
        const sx = @as(i64, @intCast(xx)) - dx;
        const sy = @as(i64, @intCast(yy)) - dy;
        const dst = px[(yy * f.width + xx) * 4 ..][0..4];
        dst.* = if (sx < 0 or sy < 0 or sx >= w or sy >= h) fill else f.pixels[@intCast((sy * w + sx) * 4)..][0..4].*;
    };
    gpa.free(f.pixels);
    f.pixels = px;
}
