//! CLI contract shared by every Zig tool in this repo: build info, the
//! version command, output envelopes and exit codes.
const std = @import("std");
const builtin = @import("builtin");
const Writer = std.Io.Writer;

/// Exit codes. Agents stop retrying on `needs_human`.
pub const exit = struct {
    pub const ok: u8 = 0;
    pub const failure: u8 = 1;
    pub const usage: u8 = 2;
    pub const needs_human: u8 = 3;
    pub const cancelled: u8 = 130;
};

pub const Format = enum {
    text,
    json,

    pub fn parse(s: []const u8) ?Format {
        return std.meta.stringToEnum(Format, s);
    }
};

/// Describes the running binary. Version fields come from build options
/// injected by `go run ./cmd/repo build`.
pub const BuildInfo = struct {
    name: []const u8,
    version: []const u8,
    commit: []const u8,
    date: []const u8,
    os: []const u8 = osName(),
    arch: []const u8 = archName(),
};

/// GOOS-style OS name, so every tool reports the same platform names.
pub fn osName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        else => @tagName(builtin.os.tag),
    };
}

/// GOARCH-style architecture name.
pub fn archName() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => @tagName(builtin.cpu.arch),
    };
}

/// Writes the output of `version` / `--version`.
pub fn writeVersion(w: *Writer, info: BuildInfo, format: Format) Writer.Error!void {
    switch (format) {
        .json => try writeOk(w, info),
        .text => {
            try w.print("{s} {s} ({s}/{s}", .{ info.name, info.version, info.os, info.arch });
            if (info.commit.len > 0) try w.print(", {s}", .{info.commit});
            if (info.date.len > 0) try w.print(", {s}", .{info.date});
            try w.writeAll(")\n");
        },
    }
}

/// Writes {"ok":true,"data":...} as a single JSON object.
pub fn writeOk(w: *Writer, data: anytype) Writer.Error!void {
    try std.json.Stringify.value(.{ .ok = true, .data = data }, .{}, w);
    try w.writeByte('\n');
}

pub const Failure = struct {
    code: []const u8,
    message: []const u8,
    retryable: bool = false,
};

/// Writes {"ok":false,"error":{...}} as a single JSON object.
pub fn writeError(w: *Writer, failure: Failure) Writer.Error!void {
    try std.json.Stringify.value(.{ .ok = false, .@"error" = failure }, .{}, w);
    try w.writeByte('\n');
}

/// Reports a failure: JSON to stdout as a single object, text to stderr.
/// Returns the exit code to use.
pub fn fail(stdout: *Writer, stderr: *Writer, format: Format, failure: Failure, code: u8) Writer.Error!u8 {
    switch (format) {
        .json => try writeError(stdout, failure),
        .text => try stderr.print("error: {s}\n", .{failure.message}),
    }
    return code;
}

pub fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

/// Walks command arguments. Supports `--flag value` and `--flag=value`.
pub const ArgIterator = struct {
    args: []const [:0]const u8,
    index: usize = 0,

    pub fn next(self: *ArgIterator) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        defer self.index += 1;
        return self.args[self.index];
    }

    /// Returns the value when `arg` is `flag`, consuming the next argument
    /// for the `--flag value` form; null when `arg` is a different flag.
    pub fn value(self: *ArgIterator, arg: []const u8, flag: []const u8) error{MissingValue}!?[]const u8 {
        if (!std.mem.startsWith(u8, arg, flag)) return null;
        const rest = arg[flag.len..];
        if (rest.len > 0) return if (rest[0] == '=') rest[1..] else null;
        return self.next() orelse error.MissingValue;
    }
};

/// Finds --format in raw args, so errors raised before parsing finishes
/// still honour --format json.
pub fn scanFormat(args: []const [:0]const u8) Format {
    var it: ArgIterator = .{ .args = args };
    while (it.next()) |arg| {
        const v = (it.value(arg, "--format") catch null) orelse continue;
        if (Format.parse(v)) |f| return f;
    }
    return .text;
}

test "arg iterator" {
    var it: ArgIterator = .{ .args = &.{ "--name", "a", "--format=json", "x" } };
    try std.testing.expectEqualStrings("a", (try it.value(it.next().?, "--name")).?);
    const f = it.next().?;
    try std.testing.expectEqual(null, try it.value(f, "--name"));
    try std.testing.expectEqualStrings("json", (try it.value(f, "--format")).?);
    try std.testing.expectEqual(null, try it.value(it.next().?, "--format"));
    try std.testing.expectEqual(Format.json, scanFormat(&.{ "--bogus", "--format", "json" }));
    var missing: ArgIterator = .{ .args = &.{"--name"} };
    try std.testing.expectError(error.MissingValue, missing.value(missing.next().?, "--name"));
}

test "version json" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeVersion(&w, .{ .name = "x", .version = "1.2.3", .commit = "", .date = "", .os = "linux", .arch = "amd64" }, .json);
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"data\":{\"name\":\"x\",\"version\":\"1.2.3\",\"commit\":\"\",\"date\":\"\",\"os\":\"linux\",\"arch\":\"amd64\"}}\n",
        w.buffered(),
    );
}

test "version text" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeVersion(&w, .{ .name = "x", .version = "dev", .commit = "abc", .date = "", .os = "linux", .arch = "amd64" }, .text);
    try std.testing.expectEqualStrings("x dev (linux/amd64, abc)\n", w.buffered());
}

test "error json" {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeError(&w, .{ .code = "usage", .message = "bad" });
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":{\"code\":\"usage\",\"message\":\"bad\",\"retryable\":false}}\n",
        w.buffered(),
    );
}
