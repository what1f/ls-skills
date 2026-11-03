//! Thin HTTP layer: one request, the whole response in memory.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Response = struct {
    status: u16,
    body: []u8,
    /// `Retry-After` in seconds, when the server sent the numeric form.
    retry_after: ?u32 = null,
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
    extra_headers: []const std.http.Header = &.{},
    payload: ?[]const u8 = null,
};

/// Sends one request; the body is owned by `gpa`. `detail` receives the
/// underlying error name on `error.Network`.
pub fn send(client: *std.http.Client, gpa: Allocator, url: []const u8, o: Options, detail: *[]const u8) Error!Response {
    var body: std.Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();
    const result = fetch(client, url, o, &body.writer) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            detail.* = @errorName(err);
            return error.Network;
        },
    };
    return .{ .status = result.status, .body = try body.toOwnedSlice(), .retry_after = result.retry_after };
}

/// std.http.Client.fetch, plus reading `Retry-After` from the head.
fn fetch(client: *std.http.Client, url: []const u8, o: Options, out: *std.Io.Writer) !struct { status: u16, retry_after: ?u32 } {
    const uri = try std.Uri.parse(url);
    var req = try client.request(o.method, uri, .{
        .redirect_behavior = if (o.payload == null) @fromBackingInt(@intCast(3)) else .unhandled,
        .headers = .{
            .content_type = if (o.content_type) |c| .{ .override = c } else .default,
            .user_agent = .{ .override = "imgen" },
            // Not privileged_headers: Zig 0.17 never sends those.
            .authorization = if (o.authorization) |a| .{ .override = a } else .default,
        },
        .extra_headers = o.extra_headers,
    });
    defer req.deinit();

    if (o.payload) |payload| {
        req.transfer_encoding = .{ .content_length = payload.len };
        var b = try req.sendBodyUnflushed(&.{});
        try b.writer.writeAll(payload);
        try b.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(if (o.payload == null) &redirect_buffer else &.{});
    var retry_after: ?u32 = null;
    var headers = response.head.iterateHeaders();
    while (headers.next()) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "retry-after")) retry_after = std.fmt.parseInt(u32, std.mem.trim(u8, h.value, " "), 10) catch null;
    }
    const status: u16 = @backingInt(response.head.status);

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try client.allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer client.allocator.free(decompress_buffer);
    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(out) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };
    return .{ .status = status, .retry_after = retry_after };
}
