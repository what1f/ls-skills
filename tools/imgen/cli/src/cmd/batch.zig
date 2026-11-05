//! `imgen batch`: many generate jobs from a JSONL file, sharing one pool of
//! parallel requests.
const std = @import("std");
const clikit = @import("clikit");
const Ctx = @import("../ctx.zig").Ctx;
const generate = @import("generate.zig");
const provider = @import("../provider.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Failure = clikit.Failure;

pub const usage =
    \\Run many generate jobs from a JSONL file. Jobs run in parallel; failures
    \\that can be retried are retried with backoff.
    \\
    \\Usage:
    \\  imgen batch --input jobs.jsonl --out-dir DIR [flags]
    \\
    \\Each line is one job, a JSON object with these fields (only prompt is
    \\required):
    \\  prompt, variants, n, images, mask, provider, model, aspect, size,
    \\  quality, background, chroma_key, output_format, compression, out
    \\out is a file name under --out-dir (default 001-<words of the prompt>).
    \\images and mask are paths relative to the current directory. Blank lines
    \\and lines starting with # are skipped.
    \\
    \\Flags:
    \\  --input PATH             JSONL file ('-' for stdin)
    \\  --out-dir DIR            Where images are written
    \\  --max-attempts N         Tries per image for retryable errors (default 3)
    \\  --fail-fast              Stop starting new images after the first failure
    \\  --concurrency N          Parallel requests across all jobs (default 4)
    \\  --timeout SECONDS        Per request (default 300)
    \\  --force                  Overwrite existing files
    \\  --dry-run                Print the plan without sending requests
    \\  --format text|json       Output format (default text)
    \\
    \\Any other generate flag (--model, --aspect, --quality, --background…) sets
    \\the default for every line; a line's own fields win.
    \\
;

const max_lines = 1000;

const Line = struct {
    number: usize,
    plan: generate.Plan,
};

pub fn run(ctx: Ctx, args: []const [:0]const u8) !u8 {
    const a = ctx.arena;
    const scanned = clikit.scanFormat(args);
    const fail = struct {
        fn f(c: Ctx, fmt: clikit.Format, message: []const u8) !u8 {
            return clikit.fail(c.stdout, c.stderr, fmt, .{ .code = "usage", .message = message }, clikit.exit.usage);
        }
    }.f;

    // Batch-only flags; the rest go to generate's parser as defaults.
    var input: ?[]const u8 = null;
    var out_dir: ?[]const u8 = null;
    var max_attempts: u8 = 3;
    var fail_fast = false;
    var rest: std.ArrayList([:0]const u8) = .empty;
    var it: clikit.ArgIterator = .{ .args = args };
    while (it.next()) |arg| {
        if (clikit.isHelp(arg)) {
            try ctx.stdout.writeAll(usage);
            return clikit.exit.ok;
        }
        if (std.mem.eql(u8, arg, "--fail-fast")) {
            fail_fast = true;
            continue;
        }
        if (it.value(arg, "--input") catch return fail(ctx, scanned, "--input needs a value")) |v| {
            input = v;
        } else if (it.value(arg, "--out-dir") catch return fail(ctx, scanned, "--out-dir needs a value")) |v| {
            out_dir = v;
        } else if (it.value(arg, "--max-attempts") catch return fail(ctx, scanned, "--max-attempts needs a value")) |v| {
            max_attempts = std.fmt.parseInt(u8, v, 10) catch 0;
            if (max_attempts == 0 or max_attempts > 10) return fail(ctx, scanned, "--max-attempts must be 1-10");
        } else if (std.mem.eql(u8, arg, "--out") or std.mem.startsWith(u8, arg, "--out=")) {
            return fail(ctx, scanned, "batch writes to --out-dir; name files with the out field of each line");
        } else if (std.mem.eql(u8, arg, "--prompt-file") or std.mem.startsWith(u8, arg, "--prompt-file=")) {
            return fail(ctx, scanned, "put prompts in the JSONL file");
        } else {
            try rest.append(a, args[it.index - 1]);
        }
    }
    const base = switch (try generate.parseInto(a, .{}, rest.items)) {
        .help => unreachable,
        .fail => |m| return fail(ctx, scanned, m),
        .ok => |o| o,
    };
    const format = base.format;
    const in_path = input orelse return fail(ctx, format, "--input is required");
    const dir = out_dir orelse return fail(ctx, format, "--out-dir is required");

    const text = readInput(ctx, in_path) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return fail(ctx, format, try std.fmt.allocPrint(a, "{s}: cannot read ({s})", .{ in_path, @errorName(err) })),
    };

    const reg = switch (try generate.loadRegistry(ctx)) {
        .fail => |f| return clikit.fail(ctx.stdout, ctx.stderr, format, f.failure, f.exit),
        .reg => |r| r,
    };

    // Plan every line before sending anything: a bad line stops the batch.
    var lines: std.ArrayList(Line) = .empty;
    var used: std.StringHashMapUnmanaged(usize) = .empty;
    var rows = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (rows.next()) |raw| {
        number += 1;
        const row = std.mem.trim(u8, raw, " \t\r");
        if (row.len == 0 or row[0] == '#') continue;
        if (lines.items.len == max_lines) return fail(ctx, format, std.fmt.comptimePrint("at most {d} jobs per batch", .{max_lines}));
        const line_fail = struct {
            fn f(c: Ctx, fmt: clikit.Format, n: usize, code: []const u8, message: []const u8, exit: u8) !u8 {
                const m = try std.fmt.allocPrint(c.arena, "line {d}: {s}", .{ n, message });
                return clikit.fail(c.stdout, c.stderr, fmt, .{ .code = code, .message = m }, exit);
            }
        }.f;

        const line_args = switch (try toArgs(a, row)) {
            .args => |x| x,
            .fail => |m| return line_fail(ctx, format, number, "usage", m, clikit.exit.usage),
        };
        var o = switch (try generate.parseInto(a, base, line_args.args)) {
            .help => unreachable,
            .fail => |m| return line_fail(ctx, format, number, "usage", m, clikit.exit.usage),
            .ok => |o| o,
        };
        const name = o.out orelse try defaultName(a, lines.items.len + 1, o.prompt orelse "");
        if (std.fs.path.isAbsolute(name) or std.mem.indexOf(u8, name, "..") != null) return line_fail(ctx, format, number, "usage", "out must be a file name inside --out-dir", clikit.exit.usage);
        o.out = if (std.mem.eql(u8, dir, ".")) name else try std.fs.path.join(a, &.{ dir, name });
        o.out_dir = null;
        if (generate.validate(o)) |m| return line_fail(ctx, format, number, "usage", m, clikit.exit.usage);

        const plan = switch (try generate.makePlan(ctx, reg, o)) {
            .fail => |f| return line_fail(ctx, format, number, f.failure.code, f.failure.message, f.exit),
            .plan => |p| p,
        };
        for (plan.jobs) |*job| {
            const gop = try used.getOrPut(a, job.path);
            if (gop.found_existing) return line_fail(ctx, format, number, "usage", try std.fmt.allocPrint(a, "{s} is also written by line {d}", .{ job.path, gop.value_ptr.* }), clikit.exit.usage);
            gop.value_ptr.* = number;
            job.label = try std.fmt.allocPrint(a, "line {d} {s}", .{ number, job.path });
        }
        try lines.append(a, .{ .number = number, .plan = plan });
    }
    if (lines.items.len == 0) return fail(ctx, format, try std.fmt.allocPrint(a, "{s} has no jobs", .{in_path}));

    if (base.dry_run) return writeDryRun(ctx, format, lines.items);

    // One credential lookup per provider.
    var keys: std.StringHashMapUnmanaged(?[]const u8) = .empty;
    for (lines.items) |*l| {
        const call = l.plan.call;
        if (keys.get(call.provider.name)) |k| {
            call.key = k;
            continue;
        }
        if (try generate.authorize(ctx, call)) |f| return clikit.fail(ctx.stdout, ctx.stderr, format, f.failure, f.exit);
        try keys.put(a, call.provider.name, call.key);
    }

    var jobs: std.ArrayList(*generate.Job) = .empty;
    for (lines.items) |l| for (l.plan.jobs) |*j| try jobs.append(a, j);

    var client = generate.newClient(ctx);
    defer client.deinit();
    const start = Io.Timestamp.now(ctx.io, .awake);
    try ctx.stderr.print("running {d} job(s), {d} image(s)\n", .{ lines.items.len, jobs.items.len });
    try ctx.stderr.flush();
    generate.execute(ctx, &client, jobs.items, .{
        .concurrency = base.concurrency,
        .timeout = base.timeout,
        .force = base.force,
        .max_attempts = max_attempts,
        .fail_fast = fail_fast,
        .progress = true,
    });
    const elapsed_ms = start.untilNow(ctx.io, .awake).toMilliseconds();
    return writeResult(ctx, format, lines.items, elapsed_ms);
}

fn readInput(ctx: Ctx, path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, path, "-")) {
        var buf: [4096]u8 = undefined;
        var r: Io.File.Reader = .init(.stdin(), ctx.io, &buf);
        return r.interface.allocRemaining(ctx.arena, .limited(16 << 20));
    }
    return Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(16 << 20));
}

/// `001-a-red-fox`, from the first words of the prompt; `001` when nothing
/// ASCII is left.
fn defaultName(a: Allocator, index: usize, prompt: []const u8) ![]const u8 {
    var slug: std.ArrayList(u8) = .empty;
    var dash = false;
    for (prompt) |c| {
        if (slug.items.len >= 32) break;
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and slug.items.len > 0) try slug.append(a, '-');
            dash = false;
            try slug.append(a, std.ascii.toLower(c));
        } else dash = true;
    }
    const s = std.mem.trimEnd(u8, slug.items, "-");
    if (s.len == 0) return std.fmt.allocPrint(a, "{d:0>3}.png", .{index});
    return std.fmt.allocPrint(a, "{d:0>3}-{s}.png", .{ index, s });
}

const fields = [_]struct { json: []const u8, flag: [:0]const u8, kind: enum { string, int, list } }{
    .{ .json = "prompt", .flag = "--prompt", .kind = .string },
    .{ .json = "variants", .flag = "--variant", .kind = .list },
    .{ .json = "n", .flag = "--n", .kind = .int },
    .{ .json = "images", .flag = "--image", .kind = .list },
    .{ .json = "mask", .flag = "--mask", .kind = .string },
    .{ .json = "provider", .flag = "--provider", .kind = .string },
    .{ .json = "model", .flag = "--model", .kind = .string },
    .{ .json = "aspect", .flag = "--aspect", .kind = .string },
    .{ .json = "size", .flag = "--size", .kind = .string },
    .{ .json = "quality", .flag = "--quality", .kind = .string },
    .{ .json = "background", .flag = "--background", .kind = .string },
    .{ .json = "chroma_key", .flag = "--chroma-key", .kind = .string },
    .{ .json = "output_format", .flag = "--output-format", .kind = .string },
    .{ .json = "compression", .flag = "--compression", .kind = .int },
    .{ .json = "out", .flag = "--out", .kind = .string },
};

const Args = union(enum) {
    args: struct { args: []const [:0]const u8 },
    fail: []const u8,
};

/// Turns one JSON line into generate flags.
fn toArgs(a: Allocator, row: []const u8) !Args {
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, row, .{}) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return .{ .fail = "not a valid JSON object" },
    };
    if (value != .object) return .{ .fail = "not a JSON object" };
    if (value.object.get("prompt") == null) return .{ .fail = "prompt is required" };
    var out: std.ArrayList([:0]const u8) = .empty;
    var entries = value.object.iterator();
    next: while (entries.next()) |e| {
        const key = e.key_ptr.*;
        const v = e.value_ptr.*;
        for (fields) |f| if (std.mem.eql(u8, key, f.json)) {
            switch (f.kind) {
                .string => {
                    if (v != .string) return .{ .fail = try std.fmt.allocPrint(a, "{s} must be a string", .{key}) };
                    try out.appendSlice(a, &.{ f.flag, try a.dupeSentinel(u8, v.string, 0) });
                },
                .int => {
                    if (v != .integer) return .{ .fail = try std.fmt.allocPrint(a, "{s} must be a number", .{key}) };
                    try out.appendSlice(a, &.{ f.flag, try std.fmt.allocPrintSentinel(a, "{d}", .{v.integer}, 0) });
                },
                .list => {
                    if (v != .array) return .{ .fail = try std.fmt.allocPrint(a, "{s} must be a list of strings", .{key}) };
                    for (v.array.items) |item| {
                        if (item != .string) return .{ .fail = try std.fmt.allocPrint(a, "{s} must be a list of strings", .{key}) };
                        try out.appendSlice(a, &.{ f.flag, try a.dupeSentinel(u8, item.string, 0) });
                    }
                },
            }
            continue :next;
        };
        return .{ .fail = try std.fmt.allocPrint(a, "unknown field \"{s}\"", .{key}) };
    }
    return .{ .args = .{ .args = out.items } };
}

const LineOut = struct {
    line: usize,
    ok: bool,
    provider: []const u8,
    model: []const u8,
    transparent: ?[]const u8,
    warnings: []const []const u8,
    images: []const generate.ImageOut,
};

fn writeResult(ctx: Ctx, format: clikit.Format, lines: []Line, elapsed_ms: i64) !u8 {
    const a = ctx.arena;
    const outs = try a.alloc(LineOut, lines.len);
    var all: std.ArrayList(generate.ImageOut) = .empty;
    var succeeded: usize = 0;
    for (lines, outs) |*l, *out| {
        try generate.resultWarnings(a, l.plan.jobs, &l.plan.warnings);
        const images = try generate.imagesOut(a, l.plan.jobs);
        try all.appendSlice(a, images);
        const ok = for (images) |img| {
            if (!img.ok) break false;
        } else true;
        if (ok) succeeded += 1;
        out.* = .{
            .line = l.number,
            .ok = ok,
            .provider = l.plan.call.provider.name,
            .model = l.plan.call.model,
            .transparent = l.plan.transparent,
            .warnings = l.plan.warnings.items,
            .images = images,
        };
    }
    const top = try generate.topFailure(a, all.items);
    const data = .{ .succeeded = succeeded, .failed = lines.len - succeeded, .elapsed_ms = elapsed_ms, .jobs = outs };
    switch (format) {
        .json => {
            if (top) |t| {
                try std.json.Stringify.value(.{ .ok = false, .@"error" = t, .data = data }, generate.json_options, ctx.stdout);
            } else {
                try std.json.Stringify.value(.{ .ok = true, .data = data }, generate.json_options, ctx.stdout);
            }
            try ctx.stdout.writeByte('\n');
        },
        .text => for (outs) |out| {
            for (out.warnings) |w| try ctx.stderr.print("warning: line {d}: {s}\n", .{ out.line, w });
            try generate.writeImagesText(ctx, try std.fmt.allocPrint(a, "line {d}: ", .{out.line}), out.images);
        },
    }
    return if (top) |t| generate.exitFor(t.code) else clikit.exit.ok;
}

fn writeDryRun(ctx: Ctx, format: clikit.Format, lines: []const Line) !u8 {
    const a = ctx.arena;
    switch (format) {
        .json => {
            const Out = struct { line: usize, plan: generate.DryRun };
            const outs = try a.alloc(Out, lines.len);
            for (lines, outs) |l, *o| o.* = .{ .line = l.number, .plan = try generate.dryRunData(a, l.plan) };
            try std.json.Stringify.value(.{ .ok = true, .data = .{ .dry_run = true, .jobs = outs } }, generate.json_options, ctx.stdout);
            try ctx.stdout.writeByte('\n');
        },
        .text => for (lines, 0..) |l, i| {
            if (i > 0) try ctx.stdout.writeByte('\n');
            try ctx.stdout.print("# line {d}\n", .{l.number});
            try generate.writeDryRunText(ctx, l.plan);
        },
    }
    return clikit.exit.ok;
}

// ---------------------------------------------------------------------------
// Tests (no network)

const testing = std.testing;
const TestCtx = @import("../ctx.zig").TestCtx;

test "default names" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("001-a-red-fox-on-snow.png", try defaultName(a, 1, "A red fox, on snow!"));
    try testing.expectEqualStrings("012.png", try defaultName(a, 12, "一只狐狸"));
}

test "batch dry run merges defaults and line fields" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try t.env.put("IMGEN_PROVIDER", "codex");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "jobs.jsonl", .data =
        \\# comment
        \\{"prompt":"a fox","aspect":"16:9"}
        \\
        \\{"prompt":"an owl","variants":["day","night"],"out":"owl.png"}
        \\
    });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", t.arena.allocator());
    const input = try std.fs.path.joinZ(t.arena.allocator(), &.{ dir, "jobs.jsonl" });
    const code = try run(t.ctx(), &.{ "--input", input, "--out-dir", "/nonexistent-imgen/out", "--quality", "low", "--dry-run", "--format", "json" });
    try testing.expectEqual(clikit.exit.ok, code);
    const out = t.out.written();
    try testing.expect(std.mem.indexOf(u8, out, "\"line\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"path\":\"/nonexistent-imgen/out/001-a-fox.png\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Aspect ratio 16:9.") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"path\":\"/nonexistent-imgen/out/owl-2.png\",\"variant\":\"night\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "codex ignores --quality") != null);
}

test "batch rejects bad lines before sending" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try t.env.put("IMGEN_PROVIDER", "codex");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "jobs.jsonl", .data = "{\"prompt\":\"a\"}\n{\"prompt\":\"b\",\"colour\":\"red\"}\n" });
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", t.arena.allocator());
    const input = try std.fs.path.joinZ(t.arena.allocator(), &.{ dir, "jobs.jsonl" });
    const code = try run(t.ctx(), &.{ "--input", input, "--out-dir", "/nonexistent-imgen/out", "--format", "json" });
    try testing.expectEqual(clikit.exit.usage, code);
    try testing.expect(std.mem.indexOf(u8, t.out.written(), "line 2: unknown field \\\"colour\\\"") != null);
}

test "batch rejects --out" {
    var t: TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try testing.expectEqual(clikit.exit.usage, try run(t.ctx(), &.{ "--input", "x", "--out", "y.png" }));
}
