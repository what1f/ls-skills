//! `imgen resize`: local PNG downscaling, no network.
const std = @import("std");
const clikit = @import("clikit");
const Ctx = @import("../ctx.zig").Ctx;
const resize = @import("../image/resize.zig");
const local = @import("local.zig");

pub const usage =
    \\Shrink a PNG, keeping its aspect ratio. Never enlarges. Runs locally.
    \\
    \\Usage:
    \\  imgen resize --image IN.png --out OUT.png (--max-dim N | --width N | --height N) [flags]
    \\
    \\Flags:
    \\  --image PATH         Input PNG
    \\  --out PATH           Output PNG
    \\  --max-dim N          Longest edge
    \\  --width N            Target width
    \\  --height N           Target height
    \\  --force              Overwrite --out
    \\  --format text|json   Output format (default text)
    \\
;

pub fn run(ctx: Ctx, args: []const [:0]const u8) !u8 {
    var image: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var target: ?resize.Target = null;
    var targets: u8 = 0;
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
        if (eql(u8, arg, "--force")) {
            force = true;
        } else inline for (.{ "--image", "--out", "--max-dim", "--width", "--height", "--format" }) |flag| {
            if (it.value(arg, flag) catch return fail(ctx, scanned, flag ++ " needs a value")) |v| {
                if (comptime eql(u8, flag, "--image")) image = v;
                if (comptime eql(u8, flag, "--out")) out = v;
                if (comptime eql(u8, flag, "--format")) format = clikit.Format.parse(v) orelse return fail(ctx, .text, "--format must be text or json");
                if (comptime (eql(u8, flag, "--max-dim") or eql(u8, flag, "--width") or eql(u8, flag, "--height"))) {
                    const n = std.fmt.parseInt(u32, v, 10) catch 0;
                    if (n == 0) return fail(ctx, scanned, flag ++ " must be a positive number");
                    target = if (comptime eql(u8, flag, "--max-dim")) .{ .max_dim = n } else if (comptime eql(u8, flag, "--width")) .{ .width = n } else .{ .height = n };
                    targets += 1;
                }
                break;
            }
        } else return fail(ctx, scanned, try std.fmt.allocPrint(ctx.arena, "unknown argument \"{s}\" (see --help)", .{arg}));
    }
    const in_path = image orelse return fail(ctx, format, "--image is required");
    const out_path = out orelse return fail(ctx, format, "--out is required");
    if (targets != 1) return fail(ctx, format, "pass exactly one of --max-dim, --width or --height");
    if (try local.checkOut(ctx, out_path, force)) |f| return clikit.fail(ctx.stdout, ctx.stderr, format, f, clikit.exit.usage);

    const src = switch (try local.load(ctx, in_path)) {
        .image => |i| i,
        .fail => |f| return clikit.fail(ctx.stdout, ctx.stderr, format, f, local.exitFor(f)),
    };
    defer src.deinit(ctx.gpa);
    const size = resize.fit(src.width, src.height, target.?);
    const img = try resize.resize(ctx.gpa, src, size.w, size.h);
    defer img.deinit(ctx.gpa);
    const bytes = switch (try local.save(ctx, out_path, img, force)) {
        .bytes => |b| b,
        .fail => |f| return clikit.fail(ctx.stdout, ctx.stderr, format, f, local.exitFor(f)),
    };
    switch (format) {
        .json => try clikit.writeOk(ctx.stdout, .{ .path = out_path, .width = img.width, .height = img.height, .bytes = bytes }),
        .text => try ctx.stdout.print("{s}\n", .{out_path}),
    }
    return clikit.exit.ok;
}

test "resize needs one target" {
    var t: @import("../ctx.zig").TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try std.testing.expectEqual(clikit.exit.usage, try run(t.ctx(), &.{ "--image", "a.png", "--out", "b.png", "--width", "1", "--height", "2", "--format", "json" }));
    try std.testing.expect(std.mem.indexOf(u8, t.out.written(), "exactly one of") != null);
}
