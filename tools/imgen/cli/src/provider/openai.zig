//! OpenAI Images protocol, used by openai, codex and OpenAI-compatible
//! providers. Edits go as multipart (OpenAI) or as JSON with data URLs
//! (Codex), per the provider's `edit_format`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const sniff = @import("../image/sniff.zig");
const clikit = @import("clikit");

pub const InputImage = struct {
    data: []const u8,
    format: sniff.Format,
};

pub const Request = struct {
    model: []const u8,
    prompt: []const u8,
    size: ?[]const u8 = null,
    quality: ?[]const u8 = null,
    background: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    compression: ?u8 = null,
    images: []const InputImage = &.{},
    mask: ?InputImage = null,
    /// Gemini only: `imageConfig.aspectRatio` and `imageSize`.
    aspect_ratio: ?[]const u8 = null,
    image_size: ?[]const u8 = null,

    pub fn isEdit(r: Request) bool {
        return r.images.len > 0;
    }

    pub fn path(r: Request) []const u8 {
        return if (r.isEdit()) "/images/edits" else "/images/generations";
    }
};

/// Writes the JSON request body. Input images become data URLs.
pub fn writeBody(w: *Writer, req: Request) Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("model");
    try s.write(req.model);
    try s.objectField("prompt");
    try s.write(req.prompt);
    inline for (.{ "size", "quality", "background", "output_format" }) |field| {
        if (@field(req, field)) |v| {
            try s.objectField(field);
            try s.write(v);
        }
    }
    if (req.compression) |c| {
        try s.objectField("output_compression");
        try s.write(c);
    }
    if (req.isEdit()) {
        try s.objectField("images");
        try s.beginArray();
        for (req.images) |img| try writeImageUrl(&s, img);
        try s.endArray();
        if (req.mask) |m| {
            try s.objectField("mask");
            try writeImageUrl(&s, m);
        }
    }
    try s.endObject();
}

fn writeImageUrl(s: *std.json.Stringify, img: InputImage) Writer.Error!void {
    try s.beginObject();
    try s.objectField("image_url");
    try s.beginWriteRaw();
    try s.writer.print("\"data:{s};base64,", .{img.format.mime()});
    try std.base64.standard.Encoder.encodeWriter(s.writer, img.data);
    try s.writer.writeByte('"');
    s.endWriteRaw();
    try s.endObject();
}

/// Writes a multipart/form-data edit request. `boundary` must not occur in
/// the data; use a random one.
pub fn writeMultipart(w: *Writer, req: Request, boundary: []const u8) Writer.Error!void {
    try textPart(w, boundary, "model", req.model);
    try textPart(w, boundary, "prompt", req.prompt);
    inline for (.{ "size", "quality", "background", "output_format" }) |field| {
        if (@field(req, field)) |v| try textPart(w, boundary, field, v);
    }
    if (req.compression) |c| {
        var buf: [3]u8 = undefined;
        try textPart(w, boundary, "output_compression", std.fmt.bufPrint(&buf, "{d}", .{c}) catch unreachable);
    }
    // A single image goes as `image`, several as `image[]`.
    const field = if (req.images.len == 1) "image" else "image[]";
    for (req.images, 1..) |img, i| {
        try filePart(w, boundary, field, "image", i, img);
    }
    if (req.mask) |m| try filePart(w, boundary, "mask", "mask", 1, m);
    try w.print("--{s}--\r\n", .{boundary});
}

fn textPart(w: *Writer, boundary: []const u8, name: []const u8, value: []const u8) Writer.Error!void {
    try w.print("--{s}\r\nContent-Disposition: form-data; name=\"{s}\"\r\n\r\n{s}\r\n", .{ boundary, name, value });
}

fn filePart(w: *Writer, boundary: []const u8, name: []const u8, stem: []const u8, index: usize, img: InputImage) Writer.Error!void {
    try w.print("--{s}\r\nContent-Disposition: form-data; name=\"{s}\"; filename=\"{s}-{d}{s}\"\r\nContent-Type: {s}\r\n\r\n", .{
        boundary, name, stem, index, img.format.ext(), img.format.mime(),
    });
    try w.writeAll(img.data);
    try w.writeAll("\r\n");
}

pub const ParseError = error{
    /// The body is not the expected JSON, or carries no image.
    BadResponse,
} || Allocator.Error;

pub const Image = union(enum) {
    /// Decoded bytes, owned by the caller's `gpa`.
    bytes: []u8,
    /// Some compatible providers return a download URL instead; owned by
    /// `arena`.
    url: []const u8,
};

/// Reads the first image of a successful response.
pub fn decodeImage(gpa: Allocator, arena: Allocator, body: []const u8) ParseError!Image {
    const Body = struct {
        data: []const struct { b64_json: ?[]const u8 = null, url: ?[]const u8 = null },
    };
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const parsed = std.json.parseFromSliceLeaky(Body, scratch.allocator(), body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_if_needed,
    }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.BadResponse,
    };
    if (parsed.data.len == 0) return error.BadResponse;
    const first = parsed.data[0];
    const b64 = first.b64_json orelse {
        const url = first.url orelse return error.BadResponse;
        return .{ .url = try arena.dupe(u8, url) };
    };
    const decoder = std.base64.standard.Decoder;
    const len = decoder.calcSizeForSlice(b64) catch return error.BadResponse;
    const out = try gpa.alloc(u8, len);
    errdefer gpa.free(out);
    decoder.decode(out, b64) catch return error.BadResponse;
    return .{ .bytes = out };
}

/// Maps a non-2xx response to a failure. `message` is allocated in `arena`.
pub fn mapError(arena: Allocator, status: u16, body: []const u8) Allocator.Error!clikit.Failure {
    const info = try errorInfo(arena, body);
    const message = try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ status, info.message });
    if (status == 401 or status == 403) return .{ .code = "auth", .message = message };
    if (status == 429) return .{ .code = "rate_limited", .message = message, .retryable = true };
    if (isContentPolicy(info)) return .{ .code = "content_policy", .message = message };
    return .{ .code = "provider_error", .message = message, .retryable = status >= 500 };
}

const ErrorInfo = struct {
    message: []const u8,
    code: ?[]const u8 = null,
};

/// Reads `{"error":{"message","code"}}` or `{"detail":"…"}`; falls back to
/// the raw body, shortened.
fn errorInfo(arena: Allocator, body: []const u8) Allocator.Error!ErrorInfo {
    const Body = struct {
        @"error": ?struct { message: ?[]const u8 = null, code: ?[]const u8 = null } = null,
        detail: ?std.json.Value = null,
    };
    if (std.json.parseFromSliceLeaky(Body, arena, body, .{ .ignore_unknown_fields = true })) |b| {
        if (b.@"error") |e| if (e.message) |m| return .{ .message = m, .code = e.code };
        if (b.detail) |d| switch (d) {
            .string => |m| return .{ .message = m },
            else => return .{ .message = try std.json.Stringify.valueAlloc(arena, d, .{}) },
        };
    } else |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {},
    }
    const trimmed = std.mem.trim(u8, body, " \r\n\t");
    if (trimmed.len == 0) return .{ .message = "empty response" };
    return .{ .message = trimmed[0..@min(trimmed.len, 500)] };
}

fn isContentPolicy(info: ErrorInfo) bool {
    if (info.code) |c| {
        if (std.mem.eql(u8, c, "moderation_blocked") or std.mem.eql(u8, c, "content_policy_violation")) return true;
    }
    return containsIgnoreCase(info.message, "safety system");
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

test "body for generation" {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeBody(&w, .{ .model = "m", .prompt = "a \"cat\"", .quality = "low", .compression = 80 });
    try std.testing.expectEqualStrings(
        \\{"model":"m","prompt":"a \"cat\"","quality":"low","output_compression":80}
    , w.buffered());
}

test "body for edit uses data urls" {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeBody(&w, .{
        .model = "m",
        .prompt = "p",
        .images = &.{.{ .data = "abc", .format = .png }},
        .mask = .{ .data = "xy", .format = .png },
    });
    try std.testing.expectEqualStrings(
        \\{"model":"m","prompt":"p","images":[{"image_url":"data:image/png;base64,YWJj"}],"mask":{"image_url":"data:image/png;base64,eHk="}}
    , w.buffered());
}

test "decode image" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const img = try decodeImage(gpa, a, "{\"created\":1,\"data\":[{\"b64_json\":\"aGVsbG8=\",\"generation_id\":\"x\"}],\"size\":\"1254x1254\"}");
    defer gpa.free(img.bytes);
    try std.testing.expectEqualStrings("hello", img.bytes);
    const url = try decodeImage(gpa, a, "{\"data\":[{\"url\":\"https://cdn.example.com/a.png\"}]}");
    try std.testing.expectEqualStrings("https://cdn.example.com/a.png", url.url);
    try std.testing.expectError(error.BadResponse, decodeImage(gpa, a, "{\"data\":[]}"));
    try std.testing.expectError(error.BadResponse, decodeImage(gpa, a, "<html>"));
}

test "multipart edit" {
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeMultipart(&w, .{
        .model = "m",
        .prompt = "p",
        .quality = "low",
        .images = &.{ .{ .data = "A", .format = .png }, .{ .data = "B", .format = .jpeg } },
        .mask = .{ .data = "M", .format = .png },
    }, "XX");
    try std.testing.expectEqualStrings(
        "--XX\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nm\r\n" ++
            "--XX\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\np\r\n" ++
            "--XX\r\nContent-Disposition: form-data; name=\"quality\"\r\n\r\nlow\r\n" ++
            "--XX\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"image-1.png\"\r\nContent-Type: image/png\r\n\r\nA\r\n" ++
            "--XX\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"image-2.jpg\"\r\nContent-Type: image/jpeg\r\n\r\nB\r\n" ++
            "--XX\r\nContent-Disposition: form-data; name=\"mask\"; filename=\"mask-1.png\"\r\nContent-Type: image/png\r\n\r\nM\r\n" ++
            "--XX--\r\n",
        w.buffered(),
    );
}

test "map errors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const auth = try mapError(a, 401, "{\"detail\":\"Could not parse your authentication token.\"}");
    try std.testing.expectEqualStrings("auth", auth.code);
    try std.testing.expectEqualStrings("HTTP 401: Could not parse your authentication token.", auth.message);

    const policy = try mapError(a, 400, "{\"error\":{\"message\":\"Your request was rejected\",\"code\":\"moderation_blocked\"}}");
    try std.testing.expectEqualStrings("content_policy", policy.code);

    const busy = try mapError(a, 503, "upstream down");
    try std.testing.expectEqualStrings("provider_error", busy.code);
    try std.testing.expect(busy.retryable);

    try std.testing.expect((try mapError(a, 429, "")).retryable);
}
