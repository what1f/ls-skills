//! `imgen cutout`: local chroma-key removal, no network.
const std = @import("std");
const clikit = @import("clikit");
const Ctx = @import("../ctx.zig").Ctx;
const chroma = @import("../image/chroma.zig");
const local = @import("local.zig");

pub const usage =
    \\Turn a flat background color into transparency. Runs locally.
    \\
    \\Usage:
    \\  imgen cutout --image IN.png --out OUT.png [flags]
    \\
    \\Flags:
    \\  --image PATH         Input PNG
    \\  --out PATH           Output PNG
    \\  --key auto|#RRGGBB   Background color; auto samples the image border (default auto)
    \\  --soft               Smooth, partly transparent edges (default)
    \\  --hard               Only pixels within --tolerance become transparent
    \\  --tolerance N        Hard mode color tolerance, 0-255 (default 12)
    \\  --no-despill         Keep background color reflected on edges (removed by default)
    \\  --contract N         Shrink the visible edge by N pixels (default 0)
    \\  --feather N          Blur the alpha edge by radius N (default 0)
    \\  --force              Overwrite --out
    \\  --format text|json   Output format (default text)
    \\
;

pub fn run(ctx: Ctx, args: []const [:0]const u8) !u8 {
    const a = ctx.arena;
    var image: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var force = false;
    var format: clikit.Format = .text;
    var o: chroma.Options = .{};
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
        if (eql(u8, arg, "--soft")) {
            o.soft = true;
        } else if (eql(u8, arg, "--hard")) {
            o.soft = false;
        } else if (eql(u8, arg, "--despill")) {
            o.despill = true;
        } else if (eql(u8, arg, "--no-despill")) {
            o.despill = false;
        } else if (eql(u8, arg, "--force")) {
            force = true;
        } else inline for (.{ "--image", "--out", "--key", "--tolerance", "--contract", "--feather", "--format" }) |flag| {
            if (it.value(arg, flag) catch return fail(ctx, scanned, flag ++ " needs a value")) |v| {
                if (comptime eql(u8, flag, "--image")) image = v;
                if (comptime eql(u8, flag, "--out")) out = v;
                if (comptime eql(u8, flag, "--key")) {
                    if (!eql(u8, v, "auto")) o.key = chroma.parseHex(v) orelse return fail(ctx, scanned, "--key must be auto or a color like #00ff00");
                }
                if (comptime eql(u8, flag, "--tolerance")) o.tolerance = std.fmt.parseInt(u8, v, 10) catch return fail(ctx, scanned, "--tolerance must be 0-255");
                if (comptime eql(u8, flag, "--contract")) {
                    o.contract = std.fmt.parseInt(u8, v, 10) catch 255;
                    if (o.contract > 16) return fail(ctx, scanned, "--contract must be 0-16");
                }
                if (comptime eql(u8, flag, "--feather")) {
                    o.feather = std.fmt.parseFloat(f32, v) catch -1;
                    if (!(o.feather >= 0 and o.feather <= 64)) return fail(ctx, scanned, "--feather must be 0-64");
                }
                if (comptime eql(u8, flag, "--format")) format = clikit.Format.parse(v) orelse return fail(ctx, .text, "--format must be text or json");
                break;
            }
        } else return fail(ctx, scanned, try std.fmt.allocPrint(a, "unknown argument \"{s}\" (see --help)", .{arg}));
    }
    const in_path = image orelse return fail(ctx, format, "--image is required");
    const out_path = out orelse return fail(ctx, format, "--out is required");
    if (try local.checkOut(ctx, out_path, force)) |f| return clikit.fail(ctx.stdout, ctx.stderr, format, f, clikit.exit.usage);

    const img = switch (try local.load(ctx, in_path)) {
        .image => |i| i,
        .fail => |f| return clikit.fail(ctx.stdout, ctx.stderr, format, f, local.exitFor(f)),
    };
    defer img.deinit(ctx.gpa);
    const stats = try chroma.remove(ctx.gpa, img, o);
    const bytes = switch (try local.save(ctx, out_path, img, force)) {
        .bytes => |b| b,
        .fail => |f| return clikit.fail(ctx.stdout, ctx.stderr, format, f, local.exitFor(f)),
    };

    var warnings: std.ArrayList([]const u8) = .empty;
    if (stats.matched == 0) try warnings.append(a, try std.fmt.allocPrint(a, "no pixel matched key color {s}; check --key", .{try hex(a, stats.key)}));
    const data = .{
        .path = out_path,
        .key_color = try hex(a, stats.key),
        .width = img.width,
        .height = img.height,
        .bytes = bytes,
        .transparent_ratio = ratio(stats.transparent_ratio),
        .partial_ratio = ratio(stats.partial_ratio),
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

pub fn hex(a: std.mem.Allocator, c: chroma.Rgb) ![]const u8 {
    return std.fmt.allocPrint(a, "#{x:0>2}{x:0>2}{x:0>2}", .{ c[0], c[1], c[2] });
}

/// Three decimals, so JSON shows 0.61 rather than 0.6100000143051147.
pub fn ratio(v: f32) f64 {
    return @round(@as(f64, v) * 1000) / 1000;
}

test "cutout validates flags before reading" {
    var t: @import("../ctx.zig").TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try std.testing.expectEqual(clikit.exit.usage, try run(t.ctx(), &.{ "--image", "a.png", "--out", "b.jpg", "--format", "json" }));
    try std.testing.expect(std.mem.indexOf(u8, t.out.written(), "--out must end in .png") != null);
    t.out.clearRetainingCapacity();
    try std.testing.expectEqual(clikit.exit.usage, try run(t.ctx(), &.{ "--image", "/nonexistent-imgen/a.png", "--out", "/nonexistent-imgen/b.png", "--format", "json" }));
    try std.testing.expect(std.mem.indexOf(u8, t.out.written(), "cannot read") != null);
}

test "cutout writes a transparent png" {
    const png = @import("../image/png.zig");
    var t: @import("../ctx.zig").TestCtx = undefined;
    try t.init();
    defer t.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;

    var px: [8 * 8 * 4]u8 = undefined;
    for (0..64) |i| px[i * 4 ..][0..4].* = if (i == 27 or i == 28 or i == 35 or i == 36) .{ 200, 20, 20, 255 } else .{ 0, 250, 5, 255 };
    const data = try png.encode(gpa, .{ .width = 8, .height = 8, .pixels = &px });
    defer gpa.free(data);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "in.png", .data = data });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", t.arena.allocator());
    const in = try std.fs.path.joinZ(t.arena.allocator(), &.{ dir, "in.png" });
    const out = try std.fs.path.joinZ(t.arena.allocator(), &.{ dir, "out.png" });

    try std.testing.expectEqual(clikit.exit.ok, try run(t.ctx(), &.{ "--image", in, "--out", out, "--format", "json" }));
    const written = t.out.written();
    try std.testing.expect(std.mem.indexOf(u8, written, "\"key_color\":\"#00fa05\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"transparent_ratio\":0.938") != null);
}
