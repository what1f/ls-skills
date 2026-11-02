//! hello-zig is the Zig example tool: it greets people.
const std = @import("std");
const clikit = @import("clikit");
const build_options = @import("build_options");
const Writer = std.Io.Writer;

const name = "hello-zig";

const info: clikit.BuildInfo = .{
    .name = name,
    .version = build_options.version,
    .commit = build_options.commit,
    .date = build_options.date,
};

const usage =
    \\hello-zig - greet people (Zig example tool).
    \\
    \\Usage:
    \\  hello-zig <command> [flags]
    \\
    \\Commands:
    \\  greet     Print a greeting
    \\  version   Print version information
    \\
    \\Flags:
    \\  -h, --help   Show help
    \\  --version    Print version
    \\
    \\Run 'hello-zig <command> --help' for command flags.
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
    const code = try run(args[1..], &stdout.interface, &stderr.interface);
    try stdout.interface.flush();
    try stderr.interface.flush();
    return code;
}

fn run(args: []const [:0]const u8, stdout: *Writer, stderr: *Writer) Writer.Error!u8 {
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
    if (eql(cmd, "greet")) return greet(rest, stdout, stderr);
    try stderr.print("unknown command \"{s}\"\n\n{s}", .{ cmd, usage });
    return clikit.exit.usage;
}

const version_usage =
    \\Print version information.
    \\
    \\Usage:
    \\  hello-zig version [flags]
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

const greet_usage =
    \\Print a greeting.
    \\
    \\Usage:
    \\  hello-zig greet [flags]
    \\
    \\Flags:
    \\  --name NAME          Who to greet (default world)
    \\  --format text|json   Output format (default text)
    \\
;

fn greet(args: []const [:0]const u8, stdout: *Writer, stderr: *Writer) Writer.Error!u8 {
    var format: clikit.Format = .text;
    var who: []const u8 = "world";
    var it: clikit.ArgIterator = .{ .args = args };
    while (it.next()) |arg| {
        if (clikit.isHelp(arg)) {
            try stdout.writeAll(greet_usage);
            return clikit.exit.ok;
        }
        if (it.value(arg, "--format") catch return usageError(stdout, stderr, args, "--format needs a value")) |v| {
            format = clikit.Format.parse(v) orelse return usageError(stdout, stderr, args, "--format must be text or json");
        } else if (it.value(arg, "--name") catch return usageError(stdout, stderr, args, "--name needs a value")) |v| {
            who = v;
        } else {
            return usageError(stdout, stderr, args, "unknown argument (see --help)");
        }
    }
    switch (format) {
        .text => try stdout.print("Hello, {s}!\n", .{who}),
        .json => {
            var buf: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&buf, "Hello, {s}!", .{who}) catch
                return clikit.fail(stdout, stderr, format, .{ .code = "usage", .message = "--name is too long" }, clikit.exit.usage);
            try clikit.writeOk(stdout, .{ .message = message });
        },
    }
    return clikit.exit.ok;
}

fn usageError(stdout: *Writer, stderr: *Writer, args: []const [:0]const u8, message: []const u8) Writer.Error!u8 {
    return clikit.fail(stdout, stderr, clikit.scanFormat(args), .{ .code = "usage", .message = message }, clikit.exit.usage);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "version json" {
    var out_buf: [512]u8 = undefined;
    var err_buf: [512]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var err: Writer = .fixed(&err_buf);
    try std.testing.expectEqual(clikit.exit.ok, try run(&.{ "version", "--format", "json" }, &out, &err));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "\"name\":\"" ++ name ++ "\"") != null);
}

test "unknown command" {
    var out_buf: [512]u8 = undefined;
    var err_buf: [1024]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var err: Writer = .fixed(&err_buf);
    try std.testing.expectEqual(clikit.exit.usage, try run(&.{"nope"}, &out, &err));
}

test "greet json" {
    var out_buf: [512]u8 = undefined;
    var err_buf: [512]u8 = undefined;
    var out: Writer = .fixed(&out_buf);
    var err: Writer = .fixed(&err_buf);
    try std.testing.expectEqual(clikit.exit.ok, try run(&.{ "greet", "--name=Ada", "--format", "json" }, &out, &err));
    try std.testing.expectEqualStrings("{\"ok\":true,\"data\":{\"message\":\"Hello, Ada!\"}}\n", out.buffered());
}
