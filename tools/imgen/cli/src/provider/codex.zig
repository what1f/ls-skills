//! Codex login: reads the ChatGPT access token Codex stores in auth.json.
//! The file is read fresh on every run and never written: refresh tokens are
//! single-use and Codex owns their lifecycle.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const TokenError = error{
    /// auth.json is missing.
    NotLoggedIn,
    /// auth.json exists but has no ChatGPT access token (API key mode, or a
    /// format this CLI does not understand).
    NoToken,
} || Allocator.Error;

pub fn readToken(io: Io, gpa: Allocator, path: []const u8) TokenError![]const u8 {
    const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.NotLoggedIn,
    };
    defer gpa.free(data);
    return parseToken(gpa, data);
}

fn parseToken(gpa: Allocator, data: []const u8) TokenError![]const u8 {
    const Auth = struct {
        tokens: ?struct { access_token: ?[]const u8 = null } = null,
    };
    const parsed = std.json.parseFromSlice(Auth, gpa, data, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.NoToken,
    };
    defer parsed.deinit();
    const tokens = parsed.value.tokens orelse return error.NoToken;
    const token = tokens.access_token orelse return error.NoToken;
    if (token.len == 0) return error.NoToken;
    return gpa.dupe(u8, token);
}

test "parse token" {
    const gpa = std.testing.allocator;
    const t = try parseToken(gpa, "{\"auth_mode\":\"chatgpt\",\"OPENAI_API_KEY\":null,\"tokens\":{\"access_token\":\"abc\",\"refresh_token\":\"r\"}}");
    defer gpa.free(t);
    try std.testing.expectEqualStrings("abc", t);
    try std.testing.expectError(error.NoToken, parseToken(gpa, "{\"OPENAI_API_KEY\":\"sk\"}"));
    try std.testing.expectError(error.NoToken, parseToken(gpa, "not json"));
}
