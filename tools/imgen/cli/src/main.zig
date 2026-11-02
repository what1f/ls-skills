//! imgen: generate and edit images from the command line.
const std = @import("std");
const clikit = @import("clikit");
const build_options = @import("build_options");
const Writer = std.Io.Writer;
const Ctx = @import("ctx.zig").Ctx;
const generate = @import("cmd/generate.zig");
const providers = @import("cmd/providers.zig");

const name = "imgen";

const info: clikit.BuildInfo = .{
    .name = name,
    .version = build_options.version,
    .commit = build_options.commit,
    .date = build_options.date,
};

const usage =
    \\imgen - generate and edit images with OpenAI, Gemini or a Codex login.
    \\
    \\Usage:
    \\  imgen <command> [flags]
    \\
    \\Commands:
    \\  generate    Generate or edit images
    \\  providers   List providers, credentials and model capabilities
    \\  version     Print version information
    \\
    \\Flags:
    \\  -h, --help   Show help
    \\  --version    Print version
    \\
    \\Run 'imgen <command> --help' for command flags.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    // Streaming, not positional: positional writes start at offset 0 and
    // clobber earlier output when stdout is a shared, redirected file.
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buf);
    var stderr: std.Io.File.Writer = .initStreaming(.stderr(), init.io, &err_buf);
    const ctx: Ctx = .{
        .io = init.io,
        .gpa = init.gpa,
        .arena = init.arena.allocator(),
        .env = init.environ_map,
        .stdout = &stdout.interface,
        .stderr = &stderr.interface,
    };
    const code = try run(ctx, args[1..]);
    try stdout.interface.flush();
    try stderr.interface.flush();
    return code;
}

fn run(ctx: Ctx, args: []const [:0]const u8) !u8 {
    const stdout = ctx.stdout;
    const stderr = ctx.stderr;
    if (args.len == 0) {
        try stderr.writeAll(usage);
        return clikit.exit.usage;
    }
    const cmd = args[0];
    const rest = args[1..];
    if (clikit.isHelp(cmd) or eql(cmd, "help")) {
        try stdout.writeAll(usage);
        return clikit.exit.ok;
    }
    if (eql(cmd, "--version")) {
        try clikit.writeVersion(stdout, info, .text);
        return clikit.exit.ok;
    }
    if (eql(cmd, "version")) return version(rest, stdout, stderr);
    if (eql(cmd, "generate")) return generate.run(ctx, rest);
    if (eql(cmd, "providers")) return providers.run(ctx, rest);
    try stderr.print("unknown command \"{s}\"\n\n{s}", .{ cmd, usage });
    return clikit.exit.usage;
}

const version_usage =
    \\Print version information.
    \\
    \\Usage:
    \\  imgen version [flags]
    \\
    \\Flags:
    \\  --format text|json   Output format (default text)
    \\
;

fn version(args: []const [:0]const u8, stdout: *Writer, stderr: *Writer) Writer.Error!u8 {
    var format: clikit.Format = .text;
    var it: clikit.ArgIterator = .{ .args = args };
    while (it.next()) |arg| {
        if (clikit.isHelp(arg)) {
            try stdout.writeAll(version_usage);
            return clikit.exit.ok;
        }
        const v = it.value(arg, "--format") catch return usageError(stdout, stderr, args, "--format needs a value");
        if (v) |value| {
            format = clikit.Format.parse(value) orelse return usageError(stdout, stderr, args, "--format must be text or json");
        } else {
            return usageError(stdout, stderr, args, "unknown argument (see --help)");
        }
    }
    try clikit.writeVersion(stdout, info, format);
    return clikit.exit.ok;
}

fn usageError(stdout: *Writer, stderr: *Writer, args: []const [:0]const u8, message: []const u8) Writer.Error!u8 {
    return clikit.fail(stdout, stderr, clikit.scanFormat(args), .{ .code = "usage", .message = message }, clikit.exit.usage);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test {
    _ = @import("image/sniff.zig");
    _ = @import("output.zig");
    _ = @import("provider.zig");
    _ = @import("provider/openai.zig");
    _ = @import("provider/codex.zig");
    _ = generate;
    _ = providers;
}

test "version json" {
    var t: @import("ctx.zig").TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try std.testing.expectEqual(clikit.exit.ok, try run(t.ctx(), &.{ "version", "--format", "json" }));
    try std.testing.expect(std.mem.indexOf(u8, t.out.written(), "\"name\":\"" ++ name ++ "\"") != null);
}

test "unknown command" {
    var t: @import("ctx.zig").TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try std.testing.expectEqual(clikit.exit.usage, try run(t.ctx(), &.{"nope"}));
}
