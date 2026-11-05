//! `imgen generate`: one prompt (plus variants) to N image files.
const std = @import("std");
const clikit = @import("clikit");
const Ctx = @import("../ctx.zig").Ctx;
const provider = @import("../provider.zig");
const openai = @import("../provider/openai.zig");
const http = @import("../http.zig");
const output = @import("../output.zig");
const sniff = @import("../image/sniff.zig");
const gemini = @import("../provider/gemini.zig");
const png = @import("../image/png.zig");
const chroma = @import("../image/chroma.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Failure = clikit.Failure;

pub const usage =
    \\Generate or edit images. Each image is one request; variants and --n
    \\fan out into parallel requests.
    \\
    \\Usage:
    \\  imgen generate --prompt TEXT (--out FILE | --out-dir DIR) [flags]
    \\
    \\Prompt:
    \\  --prompt TEXT            Prompt text
    \\  --prompt-file PATH       Read the prompt from a file ('-' for stdin)
    \\  --variant TEXT           Repeatable; image i uses prompt + newline + variant i
    \\  --n N                    Samples per prompt (default 1); total images <= 10
    \\
    \\Input images:
    \\  --image PATH             Repeatable, ordered, up to 16; refer to them by
    \\                           position in the prompt
    \\  --mask PATH              PNG with alpha, same size as the first --image;
    \\                           transparent pixels mark the area to change
    \\
    \\Model:
    \\  --provider NAME          Built-in (openai, gemini, codex) or from the config
    \\                           file; see 'imgen providers'
    \\  --model [PROVIDER/]NAME  e.g. openai/gpt-image-2. Default: IMGEN_MODEL,
    \\                           then "default" in the config file
    \\  --aspect W:H             Aspect ratio, e.g. 16:9
    \\  --size WxH               Exact size, when the model supports it
    \\  --quality Q              low | medium | high | auto
    \\  --background B           auto | opaque | transparent; without native
    \\                           transparency the model draws on a flat color
    \\                           that is then removed locally
    \\  --chroma-key #RRGGBB     That flat color (default #00ff00); use #ff00ff
    \\                           when the subject is green
    \\  --output-format F        png | jpeg | webp (transparent forces png)
    \\  --compression 0-100      jpeg/webp compression
    \\
    \\Output:
    \\  --out FILE               File path; -1, -2… suffixes when there are several
    \\  --out-dir DIR            Writes image-N files, skipping names already taken
    \\  --force                  Overwrite existing files
    \\  --dry-run                Print the plan without sending requests
    \\  --format text|json       Output format (default text)
    \\
    \\Requests:
    \\  --concurrency N          Parallel requests (default 4)
    \\  --timeout SECONDS        Per request (default 300)
    \\
;

const max_total = 10;
const max_input_bytes = 50 << 20;

pub const Options = struct {
    prompt: ?[]const u8 = null,
    prompt_file: ?[]const u8 = null,
    variants: []const []const u8 = &.{},
    n: u8 = 1,
    images: []const []const u8 = &.{},
    mask: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    aspect: ?Ratio = null,
    size: ?Ratio = null,
    quality: ?[]const u8 = null,
    background: ?[]const u8 = null,
    chroma_key: ?chroma.Rgb = null,
    output_format: ?sniff.Format = null,
    compression: ?u8 = null,
    out: ?[]const u8 = null,
    out_dir: ?[]const u8 = null,
    force: bool = false,
    concurrency: u8 = 4,
    timeout: u32 = 300,
    dry_run: bool = false,
    format: clikit.Format = .text,
};

pub const Ratio = struct {
    w: u32,
    h: u32,

    fn parse(s: []const u8, sep: u8) ?Ratio {
        const i = std.mem.indexOfScalar(u8, s, sep) orelse return null;
        const w = std.fmt.parseInt(u32, s[0..i], 10) catch return null;
        const h = std.fmt.parseInt(u32, s[i + 1 ..], 10) catch return null;
        if (w == 0 or h == 0) return null;
        return .{ .w = w, .h = h };
    }

    fn reduced(r: Ratio) Ratio {
        const g = std.math.gcd(r.w, r.h);
        return .{ .w = r.w / g, .h = r.h / g };
    }
};

const ParseResult = union(enum) {
    ok: Options,
    help,
    fail: []const u8,
};

fn parse(arena: Allocator, args: []const [:0]const u8) Allocator.Error!ParseResult {
    const r = try parseInto(arena, .{}, args);
    if (r == .ok) if (validate(r.ok)) |message| return .{ .fail = message };
    return r;
}

/// Applies flags on top of `base`. Repeatable flags (--variant, --image)
/// replace the base list when given. Does not check flag combinations; see
/// `validate`.
pub fn parseInto(arena: Allocator, base: Options, args: []const [:0]const u8) Allocator.Error!ParseResult {
    var o = base;
    var variants: std.ArrayList([]const u8) = .empty;
    var images: std.ArrayList([]const u8) = .empty;
    var it: clikit.ArgIterator = .{ .args = args };
    while (it.next()) |arg| {
        if (clikit.isHelp(arg)) return .help;
        if (std.mem.eql(u8, arg, "--force")) {
            o.force = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--dry-run")) {
            o.dry_run = true;
            continue;
        }
        const flag = flagName(arg) orelse return .{ .fail = try std.fmt.allocPrint(arena, "unexpected argument \"{s}\" (see --help)", .{arg}) };
        const v = (it.value(arg, flag) catch return .{ .fail = try std.fmt.allocPrint(arena, "{s} needs a value", .{flag}) }) orelse
            return .{ .fail = try std.fmt.allocPrint(arena, "unknown flag \"{s}\" (see --help)", .{arg}) };
        const eql = std.mem.eql;
        if (eql(u8, flag, "--prompt")) {
            o.prompt = v;
        } else if (eql(u8, flag, "--prompt-file")) {
            o.prompt_file = v;
        } else if (eql(u8, flag, "--variant")) {
            try variants.append(arena, v);
        } else if (eql(u8, flag, "--n")) {
            o.n = std.fmt.parseInt(u8, v, 10) catch 0;
            if (o.n == 0 or o.n > max_total) return .{ .fail = "--n must be 1-10" };
        } else if (eql(u8, flag, "--image")) {
            try images.append(arena, v);
        } else if (eql(u8, flag, "--mask")) {
            o.mask = v;
        } else if (eql(u8, flag, "--provider")) {
            o.provider = v;
        } else if (eql(u8, flag, "--model")) {
            o.model = v;
        } else if (eql(u8, flag, "--aspect")) {
            o.aspect = Ratio.parse(v, ':') orelse return .{ .fail = "--aspect must look like 16:9" };
        } else if (eql(u8, flag, "--size")) {
            o.size = Ratio.parse(v, 'x') orelse return .{ .fail = "--size must look like 1536x1024" };
        } else if (eql(u8, flag, "--quality")) {
            if (!oneOf(v, &.{ "low", "medium", "high", "auto" })) return .{ .fail = "--quality must be low, medium, high or auto" };
            o.quality = v;
        } else if (eql(u8, flag, "--background")) {
            if (!oneOf(v, &.{ "auto", "opaque", "transparent" })) return .{ .fail = "--background must be auto, opaque or transparent" };
            o.background = v;
        } else if (eql(u8, flag, "--chroma-key")) {
            o.chroma_key = chroma.parseHex(v) orelse return .{ .fail = "--chroma-key must look like #00ff00" };
        } else if (eql(u8, flag, "--output-format")) {
            o.output_format = sniff.Format.parse(v) orelse return .{ .fail = "--output-format must be png, jpeg or webp" };
        } else if (eql(u8, flag, "--compression")) {
            const c = std.fmt.parseInt(u8, v, 10) catch 255;
            if (c > 100) return .{ .fail = "--compression must be 0-100" };
            o.compression = c;
        } else if (eql(u8, flag, "--out")) {
            o.out = v;
        } else if (eql(u8, flag, "--out-dir")) {
            o.out_dir = v;
        } else if (eql(u8, flag, "--concurrency")) {
            o.concurrency = std.fmt.parseInt(u8, v, 10) catch 0;
            if (o.concurrency == 0 or o.concurrency > 16) return .{ .fail = "--concurrency must be 1-16" };
        } else if (eql(u8, flag, "--timeout")) {
            o.timeout = std.fmt.parseInt(u32, v, 10) catch 0;
            if (o.timeout == 0) return .{ .fail = "--timeout must be a positive number of seconds" };
        } else if (eql(u8, flag, "--format")) {
            o.format = clikit.Format.parse(v) orelse return .{ .fail = "--format must be text or json" };
        } else unreachable;
    }
    if (variants.items.len > 0) o.variants = variants.items;
    if (images.items.len > 0) o.images = images.items;
    return .{ .ok = o };
}

/// Checks flag combinations; returns the problem, if any.
pub fn validate(o: Options) ?[]const u8 {
    if ((o.prompt == null) == (o.prompt_file == null)) return "pass exactly one of --prompt or --prompt-file";
    if ((o.out == null) == (o.out_dir == null)) return "pass exactly one of --out or --out-dir";
    if (o.aspect != null and o.size != null) return "pass --aspect or --size, not both";
    if (o.mask != null and o.images.len == 0) return "--mask needs --image";
    if (o.images.len > 16) return "at most 16 --image";
    if (@max(o.variants.len, 1) * o.n > max_total) return "variants x n must be at most 10 images";
    return null;
}

const value_flags = [_][]const u8{
    "--prompt-file",   "--prompt",      "--variant", "--n",    "--image",       "--mask",
    "--provider",      "--model",       "--aspect",  "--size", "--quality",     "--background",
    "--output-format", "--compression", "--out-dir", "--out",  "--concurrency", "--timeout",
    "--format",        "--chroma-key",
};

/// Matches `--flag` or `--flag=value` against the known value flags.
fn flagName(arg: []const u8) ?[]const u8 {
    const name = if (std.mem.indexOfScalar(u8, arg, '=')) |i| arg[0..i] else arg;
    for (value_flags) |f| if (std.mem.eql(u8, name, f)) return f;
    return null;
}

fn oneOf(v: []const u8, options: []const []const u8) bool {
    for (options) |o| if (std.mem.eql(u8, v, o)) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Planning

/// What every request of one plan shares.
pub const Call = struct {
    provider: *const provider.Provider,
    model: []const u8,
    url: []const u8,
    request: openai.Request,
    /// Raw key or token, set by `authorize`; null for `auth = none`.
    key: ?[]const u8 = null,
    /// Remove the flat background locally after download.
    chroma: bool = false,
};

pub const Job = struct {
    call: *const Call,
    variant: ?[]const u8,
    prompt: []const u8,
    path: []const u8,
    /// Shown in progress lines.
    label: []const u8 = "",
    outcome: Outcome = .{ .failure = .{ .code = "cancelled", .message = "not run" } },
    /// From the last response, for the next retry.
    retry_after: ?u32 = null,
};

const Saved = struct {
    path: []const u8,
    format: sniff.Format,
    width: u32,
    height: u32,
    bytes: usize,
    /// Set when the extension was changed to match the returned format.
    renamed_from: ?[]const u8 = null,
    /// Chroma-key mode only.
    transparent_ratio: ?f32 = null,
};

const Outcome = union(enum) {
    saved: Saved,
    failure: Failure,
};

pub const Plan = struct {
    call: *Call,
    image_paths: []const []const u8,
    mask_path: ?[]const u8,
    transparent: ?[]const u8,
    warnings: std.ArrayList([]const u8),
    jobs: []Job,
};

/// A failure that stops a command before any request.
pub const Stop = struct { failure: Failure, exit: u8 };

pub const PlanResult = union(enum) {
    plan: Plan,
    fail: Stop,
};

fn stop(code: []const u8, message: []const u8, exit: u8) Stop {
    return .{ .failure = .{ .code = code, .message = message }, .exit = exit };
}

fn failWith(code: []const u8, message: []const u8, exit: u8) PlanResult {
    return .{ .fail = stop(code, message, exit) };
}

pub fn loadRegistry(ctx: Ctx) !union(enum) { reg: provider.Registry, fail: Stop } {
    var problem: []const u8 = "";
    const reg = provider.load(ctx.io, ctx.arena, ctx.env, &problem) catch |err| return switch (err) {
        error.OutOfMemory => |e| e,
        error.ConfigInvalid => .{ .fail = stop("config", problem, clikit.exit.usage) },
    };
    return .{ .reg = reg };
}

pub fn makePlan(ctx: Ctx, reg: provider.Registry, o: Options) !PlanResult {
    const a = ctx.arena;

    var failed: []const u8 = "";
    const sel = provider.select(ctx.io, a, reg, ctx.env, o.provider, o.model, &failed) catch |err| return switch (err) {
        error.OutOfMemory => |e| e,
        error.UnknownProvider => failWith("usage", try std.fmt.allocPrint(a, "unknown provider \"{s}\"; add it to {s} (see 'imgen providers')", .{ failed, reg.config_path }), clikit.exit.usage),
        error.Conflict => failWith("usage", "--provider and the provider prefix of --model differ", clikit.exit.usage),
        error.NoCredential => failWith("auth", "no image provider is configured: set OPENAI_API_KEY or GEMINI_API_KEY, run `codex login`, or add a provider to the config file (see 'imgen providers')", clikit.exit.needs_human),
    };
    const pv = sel.provider;
    const caps = pv.caps(sel.model);
    var warnings: std.ArrayList([]const u8) = .empty;

    if (o.images.len > 0 and !caps.edit) return failWith("unsupported", try std.fmt.allocPrint(a, "{s} cannot take input images", .{sel.model}), clikit.exit.usage);
    if (o.mask != null and !caps.mask) return failWith("unsupported", try std.fmt.allocPrint(a, "{s} does not support --mask", .{sel.model}), clikit.exit.usage);
    if (o.images.len > caps.max_images) return failWith("unsupported", try std.fmt.allocPrint(a, "{s} takes at most {d} input images", .{ sel.model, caps.max_images }), clikit.exit.usage);

    // Prompt and size.
    const prompt = try readPrompt(ctx, o) orelse return failWith("usage", "cannot read --prompt-file", clikit.exit.usage);
    var size: ?[]const u8 = null;
    var aspect_ratio: ?[]const u8 = null;
    var image_size: ?[]const u8 = null;
    var aspect_suffix: []const u8 = "";
    if (o.aspect orelse o.size) |r| switch (caps.sizes) {
        .prompt => {
            const ratio = r.reduced();
            aspect_suffix = try std.fmt.allocPrint(a, "\n\nAspect ratio {d}:{d}.", .{ ratio.w, ratio.h });
            if (o.size != null) try warnings.append(a, try std.fmt.allocPrint(a, "{s} does not take exact sizes; asked for aspect ratio {d}:{d} in the prompt instead", .{ pv.name, ratio.w, ratio.h }));
        },
        .flexible, .fixed => {
            const sz = if (o.size != null) r else if (caps.sizes == .fixed) nearestFixed(r) else flexibleSize(r) orelse
                return failWith("unsupported", "aspect ratio must be within 3:1", clikit.exit.usage);
            size = try std.fmt.allocPrint(a, "{d}x{d}", .{ sz.w, sz.h });
            if (o.aspect != null and caps.sizes == .fixed and sz.w * r.h != sz.h * r.w) {
                try warnings.append(a, try std.fmt.allocPrint(a, "{s} only has fixed sizes; using {s}", .{ sel.model, size.? }));
            }
        },
        .ratio => {
            const cfg = try gemini.imageConfig(a, sel.model, r.w, r.h, o.size != null);
            aspect_ratio = cfg.aspect_ratio;
            image_size = cfg.image_size;
            if (cfg.warning) |w| try warnings.append(a, w);
        },
    };

    // Background and format.
    var transparent: ?[]const u8 = null;
    var use_chroma = false;
    var chroma_suffix: []const u8 = "";
    var background = o.background;
    var format: sniff.Format = o.output_format orelse .png;
    if (o.background) |b| if (std.mem.eql(u8, b, "transparent")) {
        if (format != .png) try warnings.append(a, "transparent background needs PNG; saving as png");
        format = .png;
        if (caps.native_transparent) {
            transparent = "native";
        } else {
            transparent = "chroma-key";
            use_chroma = true;
            background = null;
            const k = o.chroma_key orelse chroma.Rgb{ 0, 255, 0 };
            chroma_suffix = try std.fmt.allocPrint(a,
                \\
                \\
                \\Background: a perfectly flat, uniform solid #{X:0>2}{X:0>2}{X:0>2} chroma-key background filling the whole canvas, with no shadows, gradients, texture, reflections or vignetting. Do not use #{X:0>2}{X:0>2}{X:0>2} or similar colors anywhere in the subject.
            , .{ k[0], k[1], k[2], k[0], k[1], k[2] });
        }
    };
    if (o.chroma_key != null and !use_chroma) try warnings.append(a, "--chroma-key only applies to --background transparent on models without native transparency; ignored");
    if (!caps.output_format) {
        if (format != .png) try warnings.append(a, try std.fmt.allocPrint(a, "{s} always returns PNG; saving as png", .{pv.name}));
        if (o.compression != null) try warnings.append(a, "--compression has no effect on PNG output");
        format = .png;
    }
    if (std.mem.eql(u8, background orelse "", "auto")) background = null;

    if (o.quality != null and !caps.quality) try warnings.append(a, try std.fmt.allocPrint(a, "{s} ignores --quality", .{pv.name}));

    // Input images.
    const inputs = try a.alloc(openai.InputImage, o.images.len);
    for (o.images, inputs) |path, *img| {
        img.* = (try readImage(ctx, path)) orelse return failWith("unsupported", try std.fmt.allocPrint(a, "{s}: cannot read, or not a PNG, JPEG or WebP image", .{path}), clikit.exit.usage);
    }
    var mask: ?openai.InputImage = null;
    if (o.mask) |path| {
        const m = (try readImage(ctx, path)) orelse return failWith("unsupported", try std.fmt.allocPrint(a, "{s}: cannot read mask image", .{path}), clikit.exit.usage);
        const mi = sniff.sniff(m.data).?;
        const first = sniff.sniff(inputs[0].data).?;
        if (mi.format != .png or !mi.alpha) return failWith("usage", "--mask must be a PNG with an alpha channel", clikit.exit.usage);
        if (mi.width != first.width or mi.height != first.height) return failWith("usage", try std.fmt.allocPrint(a, "--mask is {d}x{d} but the first --image is {d}x{d}", .{ mi.width, mi.height, first.width, first.height }), clikit.exit.usage);
        mask = m;
    }

    const request: openai.Request = .{
        .model = sel.model,
        .prompt = prompt,
        .size = size,
        .quality = if (caps.quality) o.quality else null,
        .background = background,
        .output_format = if (caps.output_format) @tagName(format) else null,
        .compression = if (caps.output_format and format != .png) o.compression else null,
        .images = inputs,
        .mask = mask,
        .aspect_ratio = aspect_ratio,
        .image_size = image_size,
    };
    const call = try a.create(Call);
    call.* = .{
        .provider = pv,
        .model = sel.model,
        .url = switch (pv.protocol) {
            .gemini => try std.fmt.allocPrint(a, "{s}{s}", .{ pv.base_url, try gemini.path(a, sel.model) }),
            .openai => try std.fmt.allocPrint(a, "{s}{s}", .{ pv.base_url, request.path() }),
        },
        .request = request,
        .chroma = use_chroma,
    };

    // Jobs and output paths.
    const variant_list: []const ?[]const u8 = if (o.variants.len == 0) &.{null} else blk: {
        const list = try a.alloc(?[]const u8, o.variants.len);
        for (o.variants, list) |v, *l| l.* = v;
        break :blk list;
    };
    const count = variant_list.len * o.n;
    const target: output.Target = if (o.out) |f| .{ .file = f } else .{ .dir = o.out_dir.? };
    const paths = try output.plan(a, target, count, format, ctx.io, output.fileExists);
    const jobs = try a.alloc(Job, count);
    for (jobs, 0..) |*job, i| {
        const variant = variant_list[i / o.n];
        job.* = .{
            .call = call,
            .variant = variant,
            .prompt = if (variant) |v|
                try std.fmt.allocPrint(a, "{s}\n{s}{s}{s}", .{ prompt, v, chroma_suffix, aspect_suffix })
            else
                try std.fmt.allocPrint(a, "{s}{s}{s}", .{ prompt, chroma_suffix, aspect_suffix }),
            .path = paths[i],
            .label = paths[i],
        };
        if (!o.force and output.fileExists(ctx.io, job.path)) {
            return failWith("exists", try std.fmt.allocPrint(a, "{s} already exists (use --force to overwrite)", .{job.path}), clikit.exit.usage);
        }
    }

    return .{ .plan = .{
        .call = call,
        .image_paths = o.images,
        .mask_path = o.mask,
        .transparent = transparent,
        .warnings = warnings,
        .jobs = jobs,
    } };
}

/// Reads the call's credential into `call.key`.
pub fn authorize(ctx: Ctx, call: *Call) !?Stop {
    switch (try provider.credential(ctx.io, ctx.arena, call.provider.*, ctx.env)) {
        .ok => |key| call.key = key,
        .missing => |message| return stop("auth", message, clikit.exit.needs_human),
    }
    return null;
}

/// gpt-image-1.x sizes: the one whose ratio is closest to `r`.
fn nearestFixed(r: Ratio) Ratio {
    const fixed = [_]Ratio{ .{ .w = 1024, .h = 1024 }, .{ .w = 1536, .h = 1024 }, .{ .w = 1024, .h = 1536 } };
    const want = @log(@as(f64, @floatFromInt(r.w)) / @as(f64, @floatFromInt(r.h)));
    var best = fixed[0];
    var best_d = std.math.inf(f64);
    for (fixed) |f| {
        const d = @abs(@log(@as(f64, @floatFromInt(f.w)) / @as(f64, @floatFromInt(f.h))) - want);
        if (d < best_d) {
            best = f;
            best_d = d;
        }
    }
    return best;
}

/// gpt-image-2 sizes: long edge 1536, both edges multiples of 16. Null when
/// the ratio exceeds 3:1.
fn flexibleSize(r: Ratio) ?Ratio {
    const long: u32 = 1536;
    const big = @max(r.w, r.h);
    const small = @min(r.w, r.h);
    if (big > small * 3) return null;
    const short: u32 = @intFromFloat(@round(@as(f64, @floatFromInt(long)) * @as(f64, @floatFromInt(small)) / @as(f64, @floatFromInt(big)) / 16.0) * 16.0);
    return if (r.w >= r.h) .{ .w = long, .h = short } else .{ .w = short, .h = long };
}

test "size mapping" {
    try testing.expectEqual(Ratio{ .w = 1536, .h = 1024 }, nearestFixed(.{ .w = 16, .h = 9 }));
    try testing.expectEqual(Ratio{ .w = 1024, .h = 1024 }, nearestFixed(.{ .w = 9, .h = 8 }));
    try testing.expectEqual(Ratio{ .w = 1536, .h = 864 }, flexibleSize(.{ .w = 16, .h = 9 }).?);
    try testing.expectEqual(Ratio{ .w = 1024, .h = 1536 }, flexibleSize(.{ .w = 2, .h = 3 }).?);
    try testing.expectEqual(@as(?Ratio, null), flexibleSize(.{ .w = 4, .h = 1 }));
}

fn readPrompt(ctx: Ctx, o: Options) !?[]const u8 {
    if (o.prompt) |p| return p;
    const path = o.prompt_file.?;
    if (std.mem.eql(u8, path, "-")) {
        var buf: [4096]u8 = undefined;
        var r: Io.File.Reader = .init(.stdin(), ctx.io, &buf);
        return r.interface.allocRemaining(ctx.arena, .limited(1 << 20)) catch null;
    }
    return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => |e| e,
        else => null,
    };
}

fn readImage(ctx: Ctx, path: []const u8) !?openai.InputImage {
    const data = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(max_input_bytes)) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return null,
    };
    const info = sniff.sniff(data) orelse return null;
    return .{ .data = data, .format = info.format };
}

// ---------------------------------------------------------------------------
// Running

pub const RunOptions = struct {
    concurrency: u8,
    timeout: u32,
    force: bool,
    max_attempts: u8 = 1,
    /// After the first failed job, skip the ones not started yet.
    fail_fast: bool = false,
    /// Write start, retry and finish lines to stderr.
    progress: bool = false,
};

const Shared = struct {
    io: Io,
    gpa: Allocator,
    arena: Allocator,
    stderr: *Writer,
    client: *std.http.Client,
    jobs: []const *Job,
    ro: RunOptions,
    mutex: Io.Mutex = .init,
    next: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn note(sh: *Shared, comptime fmt: []const u8, args: anytype) void {
        if (!sh.ro.progress) return;
        sh.mutex.lockUncancelable(sh.io);
        defer sh.mutex.unlock(sh.io);
        sh.stderr.print(fmt ++ "\n", args) catch {};
        sh.stderr.flush() catch {};
    }
};

/// Runs every job, filling in `outcome`. Never fails: problems end up in
/// the outcomes.
pub fn execute(ctx: Ctx, client: *std.http.Client, jobs: []const *Job, ro: RunOptions) void {
    var sh: Shared = .{ .io = ctx.io, .gpa = ctx.gpa, .arena = ctx.arena, .stderr = ctx.stderr, .client = client, .jobs = jobs, .ro = ro };
    var group: Io.Group = .init;
    const workers = @min(@max(ro.concurrency, 1), jobs.len);
    for (0..workers) |_| {
        group.concurrent(ctx.io, worker, .{&sh}) catch group.async(ctx.io, worker, .{&sh});
    }
    group.await(ctx.io) catch {};
}

fn worker(sh: *Shared) Io.Cancelable!void {
    while (true) {
        const i = sh.next.fetchAdd(1, .monotonic);
        if (i >= sh.jobs.len) return;
        const job = sh.jobs[i];
        if (sh.ro.fail_fast and sh.failed.load(.monotonic)) {
            job.outcome = .{ .failure = .{ .code = "cancelled", .message = "skipped after an earlier failure (--fail-fast)" } };
            continue;
        }
        sh.note("start {s}", .{job.label});
        var tries: u8 = 0;
        while (true) {
            tries += 1;
            job.retry_after = null;
            job.outcome = runWithTimeout(sh, job);
            const f = switch (job.outcome) {
                .saved => |s| {
                    sh.note("done {s}", .{s.path});
                    break;
                },
                .failure => |f| f,
            };
            if (!f.retryable or tries >= sh.ro.max_attempts or (sh.ro.fail_fast and sh.failed.load(.monotonic))) {
                sh.failed.store(true, .monotonic);
                sh.note("failed {s}: {s}", .{ job.label, f.message });
                break;
            }
            const backoff: u32 = @as(u32, 1) << @intCast(@min(tries - 1, 6));
            const delay = @min(job.retry_after orelse backoff, 60);
            sh.note("retry {s} in {d}s: {s}", .{ job.label, delay, f.message });
            Io.sleep(sh.io, .fromSeconds(delay), .awake) catch {
                job.outcome = cancelled;
                return;
            };
        }
    }
}

fn runWithTimeout(sh: *Shared, job: *Job) Outcome {
    const U = union(enum) {
        done: Outcome,
        timeout: Io.Cancelable!void,
    };
    var buf: [2]U = undefined;
    var sel: Io.Select(U) = .init(sh.io, &buf);
    sel.concurrent(.done, attempt, .{ sh, job }) catch return attempt(sh, job);
    sel.concurrent(.timeout, Io.sleep, .{ sh.io, .fromSeconds(sh.ro.timeout), .awake }) catch {
        // No spare concurrency for the timer: wait without a timeout.
        const r = sel.await() catch {
            sel.cancelDiscard();
            return cancelled;
        };
        sel.cancelDiscard();
        return r.done;
    };
    const first = sel.await() catch {
        sel.cancelDiscard();
        return cancelled;
    };
    sel.cancelDiscard();
    return switch (first) {
        .done => |o| o,
        .timeout => .{ .failure = .{
            .code = "timeout",
            .message = std.fmt.allocPrint(sh.arena, "no response within {d}s", .{sh.ro.timeout}) catch "request timed out",
            .retryable = true,
        } },
    };
}

const cancelled: Outcome = .{ .failure = .{ .code = "cancelled", .message = "cancelled" } };
const out_of_memory: Outcome = .{ .failure = .{ .code = "provider_error", .message = "out of memory" } };

fn attempt(sh: *Shared, job: *Job) Outcome {
    return attemptInner(sh, job) catch |err| switch (err) {
        error.OutOfMemory => out_of_memory,
    };
}

fn attemptInner(sh: *Shared, job: *Job) Allocator.Error!Outcome {
    const call = job.call;
    var payload: Writer.Allocating = .init(sh.gpa);
    defer payload.deinit();
    var req = call.request;
    req.prompt = job.prompt;

    var opts: http.Options = .{ .content_type = "application/json" };
    var gemini_headers: [1]std.http.Header = undefined;
    switch (call.provider.protocol) {
        .gemini => {
            gemini.writeBody(&payload.writer, req) catch return error.OutOfMemory;
            if (call.key) |k| {
                gemini_headers[0] = .{ .name = "x-goog-api-key", .value = k };
                opts.extra_headers = &gemini_headers;
            }
        },
        .openai => {
            if (call.key) |k| opts.authorization = try std.fmt.allocPrint(sh.arena, "Bearer {s}", .{k});
            if (req.isEdit() and call.provider.edit_format == .multipart) {
                var rnd: [12]u8 = undefined;
                sh.io.random(&rnd);
                const boundary = try std.fmt.allocPrint(sh.arena, "imgen-{x}", .{rnd});
                opts.content_type = try std.fmt.allocPrint(sh.arena, "multipart/form-data; boundary={s}", .{boundary});
                openai.writeMultipart(&payload.writer, req, boundary) catch return error.OutOfMemory;
            } else {
                openai.writeBody(&payload.writer, req) catch return error.OutOfMemory;
            }
        },
    }
    opts.payload = payload.written();

    const resp = switch (try send(sh, call.url, opts)) {
        .ok => |r| r,
        .failure => |f| return .{ .failure = f },
    };
    defer sh.gpa.free(resp.body);
    if (resp.status / 100 != 2) {
        job.retry_after = resp.retry_after;
        return .{ .failure = switch (call.provider.protocol) {
            .gemini => try gemini.mapError(sh.arena, resp.status, resp.body),
            .openai => try openai.mapError(sh.arena, resp.status, resp.body),
        } };
    }

    const no_image: Outcome = .{ .failure = .{ .code = "provider_error", .message = "response carried no image" } };
    const img: []u8 = switch (call.provider.protocol) {
        .gemini => switch (gemini.decodeImage(sh.gpa, sh.arena, resp.body) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.BadResponse => return no_image,
        }) {
            .bytes => |b| b,
            .failure => |f| return .{ .failure = f },
        },
        .openai => switch (openai.decodeImage(sh.gpa, sh.arena, resp.body) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.BadResponse => return no_image,
        }) {
            .bytes => |b| b,
            // Download without credentials: the URL usually points at a CDN.
            .url => |url| switch (try send(sh, url, .{ .method = .GET })) {
                .failure => |f| return .{ .failure = f },
                .ok => |r| if (r.status / 100 == 2) r.body else {
                    sh.gpa.free(r.body);
                    return .{ .failure = .{ .code = "provider_error", .message = try std.fmt.allocPrint(sh.arena, "image download failed: HTTP {d}", .{r.status}), .retryable = r.status >= 500 } };
                },
            },
        },
    };
    defer sh.gpa.free(img);
    const info = sniff.sniff(img) orelse return .{ .failure = .{ .code = "provider_error", .message = "response is not a PNG, JPEG or WebP image" } };

    if (call.chroma) return cutoutAndSave(sh, job, img, info.format);

    var saved: Saved = .{ .path = job.path, .format = info.format, .width = info.width, .height = info.height, .bytes = img.len };
    if (try output.fixExt(sh.arena, job.path, info.format)) |p| {
        saved.renamed_from = job.path;
        saved.path = p;
    }
    if (output.writeFile(sh.io, saved.path, img, sh.ro.force)) |failure| return .{ .failure = failure };
    return .{ .saved = saved };
}

/// Chroma-key mode: remove the flat background with cutout's defaults.
fn cutoutAndSave(sh: *Shared, job: *Job, data: []const u8, format: sniff.Format) Allocator.Error!Outcome {
    if (format != .png) return .{ .failure = .{ .code = "unsupported", .message = try std.fmt.allocPrint(sh.arena, "{s} returned {s}; the background can only be removed from PNG", .{ job.call.model, @tagName(format) }) } };
    const image = png.decode(sh.gpa, data) catch |err| return switch (err) {
        error.OutOfMemory => |e| e,
        else => .{ .failure = .{ .code = "provider_error", .message = "returned PNG could not be decoded" } },
    };
    defer image.deinit(sh.gpa);
    const stats = try chroma.remove(sh.gpa, image, .{});
    const encoded = try png.encode(sh.gpa, image);
    defer sh.gpa.free(encoded);
    if (output.writeFile(sh.io, job.path, encoded, sh.ro.force)) |failure| return .{ .failure = failure };
    return .{ .saved = .{
        .path = job.path,
        .format = .png,
        .width = image.width,
        .height = image.height,
        .bytes = encoded.len,
        .transparent_ratio = stats.transparent_ratio,
    } };
}

const Sent = union(enum) {
    ok: http.Response,
    failure: Failure,
};

fn send(sh: *Shared, url: []const u8, o: http.Options) Allocator.Error!Sent {
    var detail: []const u8 = "";
    const resp = http.send(sh.client, sh.gpa, url, o, &detail) catch |err| return switch (err) {
        error.Canceled => .{ .failure = cancelled.failure },
        error.OutOfMemory => |e| e,
        error.Network => .{ .failure = .{
            .code = "timeout",
            .message = try std.fmt.allocPrint(sh.arena, "network error: {s}", .{detail}),
            .retryable = true,
        } },
    };
    return .{ .ok = resp };
}

/// Adds warnings that depend on the results: renamed files and cutouts
/// that removed nothing.
pub fn resultWarnings(a: Allocator, jobs: []const Job, warnings: *std.ArrayList([]const u8)) !void {
    for (jobs) |job| switch (job.outcome) {
        .saved => |s| {
            if (s.renamed_from) |from| try warnings.append(a, try std.fmt.allocPrint(a, "{s}: got {s}, saved as {s}", .{ from, @tagName(s.format), s.path }));
            if (s.transparent_ratio) |r| if (r < 0.001) try warnings.append(a, try std.fmt.allocPrint(a, "{s}: no background was removed; the model probably did not draw a flat background. Regenerate, try another --chroma-key, or tune with 'imgen cutout'", .{s.path}));
        },
        .failure => {},
    };
}

pub fn newClient(ctx: Ctx) std.http.Client {
    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    client.initDefaultProxies(ctx.arena, ctx.env) catch {};
    return client;
}

// ---------------------------------------------------------------------------
// Command

pub fn run(ctx: Ctx, args: []const [:0]const u8) !u8 {
    const o = switch (try parse(ctx.arena, args)) {
        .help => {
            try ctx.stdout.writeAll(usage);
            return clikit.exit.ok;
        },
        .fail => |message| return clikit.fail(ctx.stdout, ctx.stderr, clikit.scanFormat(args), .{ .code = "usage", .message = message }, clikit.exit.usage),
        .ok => |o| o,
    };
    const reg = switch (try loadRegistry(ctx)) {
        .fail => |f| return clikit.fail(ctx.stdout, ctx.stderr, o.format, f.failure, f.exit),
        .reg => |r| r,
    };
    var plan = switch (try makePlan(ctx, reg, o)) {
        .fail => |f| return clikit.fail(ctx.stdout, ctx.stderr, o.format, f.failure, f.exit),
        .plan => |p| p,
    };

    if (o.dry_run) {
        const data = try dryRunData(ctx.arena, plan);
        switch (o.format) {
            .json => {
                try std.json.Stringify.value(.{ .ok = true, .data = data }, json_options, ctx.stdout);
                try ctx.stdout.writeByte('\n');
            },
            .text => try writeDryRunText(ctx, plan),
        }
        return clikit.exit.ok;
    }

    if (try authorize(ctx, plan.call)) |f| return clikit.fail(ctx.stdout, ctx.stderr, o.format, f.failure, f.exit);

    var client = newClient(ctx);
    defer client.deinit();

    const start = Io.Timestamp.now(ctx.io, .awake);
    if (o.format == .text) try ctx.stderr.print("generating {d} image(s) with {s} {s}\n", .{ plan.jobs.len, plan.call.provider.name, plan.call.model });
    try ctx.stderr.flush();

    const ptrs = try ctx.arena.alloc(*Job, plan.jobs.len);
    for (plan.jobs, ptrs) |*j, *p| p.* = j;
    execute(ctx, &client, ptrs, .{ .concurrency = o.concurrency, .timeout = o.timeout, .force = o.force });
    const elapsed_ms = start.untilNow(ctx.io, .awake).toMilliseconds();

    try resultWarnings(ctx.arena, plan.jobs, &plan.warnings);
    return writeResult(ctx, o, plan, elapsed_ms);
}

// ---------------------------------------------------------------------------
// Output

pub const json_options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };

pub const ImageOut = struct {
    ok: bool,
    path: ?[]const u8 = null,
    variant: ?[]const u8 = null,
    format: ?[]const u8 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    bytes: ?usize = null,
    transparent_ratio: ?f64 = null,
    @"error": ?Failure = null,
};

pub fn imagesOut(a: Allocator, jobs: []const Job) ![]ImageOut {
    const images = try a.alloc(ImageOut, jobs.len);
    for (jobs, images) |job, *img| img.* = switch (job.outcome) {
        .saved => |s| .{
            .ok = true,
            .path = s.path,
            .variant = job.variant,
            .format = @tagName(s.format),
            .width = s.width,
            .height = s.height,
            .bytes = s.bytes,
            .transparent_ratio = if (s.transparent_ratio) |r| @import("cutout.zig").ratio(r) else null,
        },
        .failure => |f| .{ .ok = false, .variant = job.variant, .@"error" = f },
    };
    return images;
}

/// All failed for one reason: that reason. Some failed: partial_failure.
pub fn topFailure(a: Allocator, images: []const ImageOut) !?Failure {
    var failed: usize = 0;
    var first: ?Failure = null;
    var same_code = true;
    for (images) |img| if (img.@"error") |f| {
        failed += 1;
        if (first) |ff| {
            if (!std.mem.eql(u8, ff.code, f.code)) same_code = false;
        } else first = f;
    };
    if (failed == 0) return null;
    if (failed == images.len and same_code) return first.?;
    return .{ .code = "partial_failure", .message = try std.fmt.allocPrint(a, "{d} of {d} images failed", .{ failed, images.len }) };
}

fn writeResult(ctx: Ctx, o: Options, plan: Plan, elapsed_ms: i64) !u8 {
    const images = try imagesOut(ctx.arena, plan.jobs);
    const top = try topFailure(ctx.arena, images);
    const data = .{
        .provider = plan.call.provider.name,
        .model = plan.call.model,
        .elapsed_ms = elapsed_ms,
        .transparent = plan.transparent,
        .warnings = plan.warnings.items,
        .images = images,
    };
    switch (o.format) {
        .json => {
            if (top) |t| {
                try std.json.Stringify.value(.{ .ok = false, .@"error" = t, .data = data }, json_options, ctx.stdout);
            } else {
                try std.json.Stringify.value(.{ .ok = true, .data = data }, json_options, ctx.stdout);
            }
            try ctx.stdout.writeByte('\n');
        },
        .text => {
            for (plan.warnings.items) |w| try ctx.stderr.print("warning: {s}\n", .{w});
            try writeImagesText(ctx, "", images);
        },
    }
    return if (top) |t| exitFor(t.code) else clikit.exit.ok;
}

/// Paths to stdout, errors to stderr.
pub fn writeImagesText(ctx: Ctx, prefix: []const u8, images: []const ImageOut) !void {
    for (images) |img| {
        if (img.ok) {
            try ctx.stdout.print("{s}\n", .{img.path.?});
        } else if (img.variant) |v| {
            try ctx.stderr.print("error: {s}[{s}] {s}\n", .{ prefix, v, img.@"error".?.message });
        } else {
            try ctx.stderr.print("error: {s}{s}\n", .{ prefix, img.@"error".?.message });
        }
    }
}

pub fn exitFor(code: []const u8) u8 {
    const eql = std.mem.eql;
    if (eql(u8, code, "auth")) return clikit.exit.needs_human;
    if (eql(u8, code, "cancelled")) return clikit.exit.cancelled;
    if (eql(u8, code, "usage") or eql(u8, code, "config") or eql(u8, code, "unsupported") or eql(u8, code, "exists")) return clikit.exit.usage;
    return clikit.exit.failure;
}

const PlannedImage = struct { path: []const u8, variant: ?[]const u8, prompt: []const u8 };

pub const DryRun = struct {
    dry_run: bool = true,
    provider: []const u8,
    model: []const u8,
    endpoint: []const u8,
    transparent: ?[]const u8,
    request: struct {
        size: ?[]const u8,
        aspect_ratio: ?[]const u8,
        image_size: ?[]const u8,
        quality: ?[]const u8,
        background: ?[]const u8,
        output_format: ?[]const u8,
        compression: ?u8,
        images: []const []const u8,
        mask: ?[]const u8,
    },
    warnings: []const []const u8,
    images: []const PlannedImage,
};

pub fn dryRunData(a: Allocator, plan: Plan) !DryRun {
    const planned = try a.alloc(PlannedImage, plan.jobs.len);
    for (plan.jobs, planned) |job, *p| p.* = .{ .path = job.path, .variant = job.variant, .prompt = job.prompt };
    const r = plan.call.request;
    return .{
        .provider = plan.call.provider.name,
        .model = plan.call.model,
        .endpoint = plan.call.url,
        .transparent = plan.transparent,
        .request = .{
            .size = r.size,
            .aspect_ratio = r.aspect_ratio,
            .image_size = r.image_size,
            .quality = r.quality,
            .background = r.background,
            .output_format = r.output_format,
            .compression = r.compression,
            .images = plan.image_paths,
            .mask = plan.mask_path,
        },
        .warnings = plan.warnings.items,
        .images = planned,
    };
}

pub fn writeDryRunText(ctx: Ctx, plan: Plan) !void {
    try ctx.stdout.print("provider  {s}\nmodel     {s}\nendpoint  {s}\n", .{ plan.call.provider.name, plan.call.model, plan.call.url });
    for (plan.warnings.items) |w| try ctx.stderr.print("warning: {s}\n", .{w});
    for (plan.jobs) |job| {
        try ctx.stdout.print("\n{s}\n", .{job.path});
        var lines = std.mem.splitScalar(u8, job.prompt, '\n');
        while (lines.next()) |line| try ctx.stdout.print("  {s}\n", .{line});
    }
}

// ---------------------------------------------------------------------------
// Tests (no network: dry runs and parsing only)

const testing = std.testing;
const TestCtx = @import("../ctx.zig").TestCtx;

test "parse rejects bad combinations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("pass exactly one of --prompt or --prompt-file", (try parse(a, &.{ "--out", "x.png" })).fail);
    try testing.expectEqualStrings("pass exactly one of --out or --out-dir", (try parse(a, &.{ "--prompt", "p" })).fail);
    try testing.expectEqualStrings("--mask needs --image", (try parse(a, &.{ "--prompt", "p", "--out", "x", "--mask", "m.png" })).fail);
    try testing.expectEqualStrings("variants x n must be at most 10 images", (try parse(a, &.{ "--prompt", "p", "--out", "x", "--n", "4", "--variant", "a", "--variant", "b", "--variant", "c" })).fail);
    const ok = (try parse(a, &.{ "--prompt=p", "--out-dir", "d", "--variant", "a", "--variant", "b", "--n", "2", "--aspect", "16:9" })).ok;
    try testing.expectEqual(@as(usize, 2), ok.variants.len);
    try testing.expectEqual(@as(u32, 16), ok.aspect.?.w);
}

test "dry run expands variants and puts aspect in the codex prompt" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try t.env.put("IMGEN_PROVIDER", "codex");
    const code = try run(t.ctx(), &.{
        "--prompt", "a fox",                      "--variant", "flat",     "--variant", "clay", "--size", "1920x1080",
        "--out",    "/nonexistent-imgen/fox.png", "--dry-run", "--format", "json",
    });
    try testing.expectEqual(clikit.exit.ok, code);
    const out = t.out.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"provider\":\"codex\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"endpoint\":\"https://chatgpt.com/backend-api/codex/images/generations\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"path\":\"/nonexistent-imgen/fox-2.png\",\"variant\":\"clay\",\"prompt\":\"a fox\\nclay\\n\\nAspect ratio 16:9.\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "does not take exact sizes") != null);
}

test "dry run forces png for transparent backgrounds" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try t.env.put("IMGEN_PROVIDER", "codex");
    const code = try run(t.ctx(), &.{ "--prompt", "p", "--background", "transparent", "--output-format", "webp", "--out", "/nonexistent-imgen/x.webp", "--dry-run", "--format", "json" });
    try testing.expectEqual(clikit.exit.ok, code);
    const out = t.out.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"transparent\":\"native\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"path\":\"/nonexistent-imgen/x.png\"") != null);
}

test "gemini dry run maps aspect ratio and falls back to chroma key" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try t.env.put("IMGEN_PROVIDER", "gemini");
    const code = try run(t.ctx(), &.{ "--prompt", "a frog", "--aspect", "16:9", "--background", "transparent", "--chroma-key", "#ff00ff", "--out", "/nonexistent-imgen/frog.png", "--dry-run", "--format", "json" });
    try testing.expectEqual(clikit.exit.ok, code);
    const out = t.out.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"endpoint\":\"https://generativelanguage.googleapis.com/v1beta/models/gemini-nano-banana-2.1:generateContent\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"transparent\":\"chroma-key\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"aspect_ratio\":\"16:9\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "solid #FF00FF chroma-key") != null);
}

test "openai without native transparency uses chroma key and drops background" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    const code = try run(t.ctx(), &.{ "--prompt", "p", "--model", "openai/gpt-image-2", "--background", "transparent", "--out", "/nonexistent-imgen/x.png", "--dry-run", "--format", "json" });
    try testing.expectEqual(clikit.exit.ok, code);
    const out = t.out.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"transparent\":\"chroma-key\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"background\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "solid #00FF00") != null);
}

test "chroma key is ignored with native transparency" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try t.env.put("IMGEN_PROVIDER", "codex");
    const code = try run(t.ctx(), &.{ "--prompt", "p", "--background", "transparent", "--chroma-key", "#ff00ff", "--out", "/nonexistent-imgen/x.png", "--dry-run", "--format", "json" });
    try testing.expectEqual(clikit.exit.ok, code);
    try testing.expect(std.mem.indexOf(u8, t.out.written(), "--chroma-key only applies") != null);
}

test "missing codex login needs a human" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try t.env.put("IMGEN_PROVIDER", "codex");
    try t.env.put("CODEX_HOME", "/nonexistent-imgen");
    const code = try run(t.ctx(), &.{ "--prompt", "p", "--out", "/nonexistent-imgen/x.png", "--format", "json" });
    try testing.expectEqual(clikit.exit.needs_human, code);
    try testing.expect(std.mem.indexOf(u8, t.out.written(), "codex login") != null);
}
