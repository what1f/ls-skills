//! `imgen sheet`: animated GIF to sprite sheet PNG, no network.
const std = @import("std");
const clikit = @import("clikit");
const Ctx = @import("../ctx.zig").Ctx;
const png = @import("../image/png.zig");
const gif = @import("../image/gif.zig");
const local = @import("local.zig");

pub const usage =
    \\Lay out the frames of an animated GIF as a sprite sheet PNG. Runs locally.
    \\
    \\Frames go left to right, then top to bottom. Use the sheet as a reference
    \\image for `imgen generate` to redraw an animation, then rebuild it with
    \\`imgen animate`.
    \\
    \\Usage:
    \\  imgen sheet --image IN.gif --out SHEET.png [flags]
    \\
    \\Flags:
    \\  --image PATH         Input GIF
    \\  --out PATH           Output PNG
    \\  --cols N             Columns (default: as square as possible)
    \\  --force              Overwrite --out
    \\  --format text|json   Output format (default text)
    \\
;

pub fn run(ctx: Ctx, args: []const [:0]const u8) !u8 {
    const a = ctx.arena;
    const gpa = ctx.gpa;
    var image: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var cols_opt: ?u32 = null;
    var force = false;
    var format: clikit.Format = .text;
    const fail = struct {
        fn f(c: Ctx, fmt: clikit.Format, code: []const u8, message: []const u8) !u8 {
            return clikit.fail(c.stdout, c.stderr, fmt, .{ .code = code, .message = message }, clikit.exit.usage);
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
        if (eql(u8, arg, "--force")) {
            force = true;
        } else inline for (.{ "--image", "--out", "--cols", "--format" }) |flag| {
            if (it.value(arg, flag) catch return fail(ctx, scanned, "usage", flag ++ " needs a value")) |v| {
                if (comptime eql(u8, flag, "--image")) image = v;
                if (comptime eql(u8, flag, "--out")) out = v;
                if (comptime eql(u8, flag, "--cols")) {
                    cols_opt = std.fmt.parseInt(u32, v, 10) catch 0;
                    if (cols_opt.? == 0) return fail(ctx, scanned, "usage", "--cols must be a positive number");
                }
                if (comptime eql(u8, flag, "--format")) format = clikit.Format.parse(v) orelse return fail(ctx, .text, "usage", "--format must be text or json");
                break;
            }
        } else return fail(ctx, scanned, "usage", try std.fmt.allocPrint(a, "unknown argument \"{s}\" (see --help)", .{arg}));
    }
    const in_path = image orelse return fail(ctx, format, "usage", "--image is required");
    const out_path = out orelse return fail(ctx, format, "usage", "--out is required");
    if (try local.checkOut(ctx, out_path, force)) |f| return clikit.fail(ctx.stdout, ctx.stderr, format, f, clikit.exit.usage);

    const bytes_in = std.Io.Dir.cwd().readFileAlloc(ctx.io, in_path, gpa, .limited(200 << 20)) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return fail(ctx, format, "usage", try std.fmt.allocPrint(a, "{s}: cannot read ({s})", .{ in_path, @errorName(err) })),
    };
    defer gpa.free(bytes_in);
    if (!gif.isGif(bytes_in)) return fail(ctx, format, "unsupported", try std.fmt.allocPrint(a, "{s}: not a GIF", .{in_path}));
    const anim = gif.decode(gpa, bytes_in) catch |err| return switch (err) {
        error.OutOfMemory => |e| e,
        error.Invalid => fail(ctx, format, "unsupported", try std.fmt.allocPrint(a, "{s}: corrupt or unreadable GIF", .{in_path})),
        error.TooLarge => fail(ctx, format, "unsupported", try std.fmt.allocPrint(a, "{s}: too many frames or pixels to lay out", .{in_path})),
    };
    defer anim.deinit(gpa);

    const n: u32 = @intCast(anim.frames.len);
    const cols = @min(n, cols_opt orelse std.math.sqrt(n - 1) + 1);
    const rows = (n + cols - 1) / cols;
    const fw = anim.width;
    const fh = anim.height;
    const sheet: png.Image = .{ .width = fw * cols, .height = fh * rows, .pixels = try gpa.alloc(u8, @as(usize, fw) * cols * fh * rows * 4) };
    defer sheet.deinit(gpa);
    @memset(sheet.pixels, 0);
    for (anim.frames, 0..) |f, i| {
        const x0 = (i % cols) * fw;
        const y0 = (i / cols) * fh;
        for (0..fh) |y| {
            const dst = ((y0 + y) * sheet.width + x0) * 4;
            @memcpy(sheet.pixels[dst..][0 .. fw * 4], f.pixels[y * fw * 4 ..][0 .. fw * 4]);
        }
    }
    const bytes = switch (try local.save(ctx, out_path, sheet, force)) {
        .bytes => |b| b,
        .fail => |f| return clikit.fail(ctx.stdout, ctx.stderr, format, f, local.exitFor(f)),
    };

    const delays = try a.alloc(u32, n);
    for (anim.delays_cs, delays) |d, *ms| ms.* = @as(u32, d) * 10;
    const data = .{
        .path = out_path,
        .frames = n,
        .grid = try std.fmt.allocPrint(a, "{d}x{d}", .{ cols, rows }),
        .frame_width = fw,
        .frame_height = fh,
        .width = sheet.width,
        .height = sheet.height,
        .delays_ms = delays,
        .bytes = bytes,
    };
    switch (format) {
        .json => try clikit.writeOk(ctx.stdout, data),
        .text => try ctx.stdout.print("{s}\n", .{out_path}),
    }
    return clikit.exit.ok;
}
