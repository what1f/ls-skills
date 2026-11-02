//! Thin HTTP layer: one request, the whole response in memory.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Response = struct {
    status: u16,
    body: []u8,
};

pub const Error = error{
    /// Connecting, TLS or reading the response failed.
    Network,
    Canceled,
} || Allocator.Error;

pub const Options = struct {
    method: std.http.Method = .POST,
    /// Authorization header value; null sends none.
    authorization: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    payload: ?[]const u8 = null,
};

/// Sends one request; the body is owned by `gpa`. `detail` receives the
/// underlying error name on `error.Network`.
pub fn send(client: *std.http.Client, gpa: Allocator, url: []const u8, o: Options, detail: *[]const u8) Error!Response {
    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = o.method,
        .payload = o.payload,
        .response_writer = &body.writer,
        .headers = .{
            .content_type = if (o.content_type) |c| .{ .override = c } else .default,
            .user_agent = .{ .override = "imgen" },
            // Not privileged_headers: Zig 0.17 never sends those.
            .authorization = if (o.authorization) |a| .{ .override = a } else .default,
        },
    }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            detail.* = @errorName(err);
            return error.Network;
        },
    };
    return .{ .status = @backingInt(result.status), .body = try body.toOwnedSlice() };
}
