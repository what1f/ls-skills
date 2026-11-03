//! Gemini generateContent protocol for image models ("Nano Banana").
//! https://ai.google.dev/api/generate-content
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const clikit = @import("clikit");
const openai = @import("openai.zig");

pub fn path(arena: Allocator, model: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "/v1beta/models/{s}:generateContent", .{model});
}

/// Text first, then the input images in order, so "image 1" in the prompt is
/// the first --image.
pub fn writeBody(w: *Writer, req: openai.Request) Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("contents");
    try s.beginArray();
    try s.beginObject();
    try s.objectField("role");
    try s.write("user");
    try s.objectField("parts");
    try s.beginArray();
    try s.write(.{ .text = req.prompt });
    for (req.images) |img| {
        try s.beginObject();
        try s.objectField("inlineData");
        try s.beginObject();
        try s.objectField("mimeType");
        try s.write(img.format.mime());
        try s.objectField("data");
        try s.beginWriteRaw();
        try s.writer.writeByte('"');
        try std.base64.standard.Encoder.encodeWriter(s.writer, img.data);
        try s.writer.writeByte('"');
        s.endWriteRaw();
        try s.endObject();
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
    try s.endArray();

    try s.objectField("generationConfig");
    try s.beginObject();
    try s.objectField("responseModalities");
    try s.write(.{"IMAGE"});
    if (req.aspect_ratio != null or req.image_size != null) {
        try s.objectField("imageConfig");
        try s.beginObject();
        if (req.aspect_ratio) |a| {
            try s.objectField("aspectRatio");
            try s.write(a);
        }
        if (req.image_size) |z| {
            try s.objectField("imageSize");
            try s.write(z);
        }
        try s.endObject();
    }
    try s.endObject();
    try s.endObject();
}

// ---------------------------------------------------------------------------
// Aspect ratio and size

const Ratio = struct { w: u32, h: u32 };

const standard = [_]Ratio{
    .{ .w = 1, .h = 1 }, .{ .w = 2, .h = 3 }, .{ .w = 3, .h = 2 },  .{ .w = 3, .h = 4 },  .{ .w = 4, .h = 3 },
    .{ .w = 4, .h = 5 }, .{ .w = 5, .h = 4 }, .{ .w = 9, .h = 16 }, .{ .w = 16, .h = 9 }, .{ .w = 21, .h = 9 },
};
const extended = standard ++ [_]Ratio{ .{ .w = 1, .h = 4 }, .{ .w = 4, .h = 1 }, .{ .w = 1, .h = 8 }, .{ .w = 8, .h = 1 } };

/// Nano Banana 2 and 2.1 add 1:4, 4:1, 1:8 and 8:1.
fn hasExtendedRatios(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "gemini-nano-banana-") or std.mem.eql(u8, model, "gemini-3.1-flash-image");
}

/// Gemini 2.5 Flash Image only makes 1K images and rejects `imageSize`.
fn hasImageSize(model: []const u8) bool {
    return !std.mem.startsWith(u8, model, "gemini-2.5-");
}

pub const ImageConfig = struct {
    aspect_ratio: []const u8,
    image_size: ?[]const u8 = null,
    /// Set when the request could not be matched exactly.
    warning: ?[]const u8 = null,
};

/// Maps an aspect ratio, or an exact WxH when `exact`, to the nearest
/// supported ratio and, for exact sizes, the smallest size tier that covers
/// the long edge.
pub fn imageConfig(arena: Allocator, model: []const u8, w: u32, h: u32, exact: bool) Allocator.Error!ImageConfig {
    const list: []const Ratio = if (hasExtendedRatios(model)) &extended else &standard;
    const want = @log(@as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h)));
    var best = list[0];
    var best_d = std.math.inf(f64);
    for (list) |r| {
        const d = @abs(@log(@as(f64, @floatFromInt(r.w)) / @as(f64, @floatFromInt(r.h))) - want);
        if (d < best_d) {
            best = r;
            best_d = d;
        }
    }
    var cfg: ImageConfig = .{ .aspect_ratio = try std.fmt.allocPrint(arena, "{d}:{d}", .{ best.w, best.h }) };
    const same_ratio = best.w * h == best.h * w;
    if (exact) {
        const long = @max(w, h);
        if (hasImageSize(model)) {
            cfg.image_size = if (long <= 512 and std.mem.eql(u8, model, "gemini-3.1-flash-image")) "512" else if (long <= 1024) "1K" else if (long <= 2048) "2K" else "4K";
        }
        cfg.warning = try std.fmt.allocPrint(arena, "{s} has no exact sizes; using aspect ratio {s} at {s}", .{ model, cfg.aspect_ratio, cfg.image_size orelse "1K" });
    } else if (!same_ratio) {
        cfg.warning = try std.fmt.allocPrint(arena, "{s} does not support {d}:{d}; using {s}", .{ model, w, h, cfg.aspect_ratio });
    }
    return cfg;
}

// ---------------------------------------------------------------------------
// Responses

pub const Decoded = union(enum) {
    /// Owned by the caller's `gpa`.
    bytes: []u8,
    failure: clikit.Failure,
};

const Part = struct {
    text: ?[]const u8 = null,
    thought: ?bool = null,
    inlineData: ?Blob = null,
    inline_data: ?Blob = null,
};
const Blob = struct {
    mimeType: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    data: []const u8,
};
const Body = struct {
    candidates: ?[]const struct {
        content: ?struct { parts: ?[]const Part = null } = null,
        finishReason: ?[]const u8 = null,
    } = null,
    promptFeedback: ?struct { blockReason: ?[]const u8 = null } = null,
};

const policy_reasons = [_][]const u8{ "SAFETY", "IMAGE_SAFETY", "PROHIBITED_CONTENT", "IMAGE_PROHIBITED_CONTENT", "BLOCKLIST", "SPII", "RECITATION", "IMAGE_RECITATION" };

/// Reads the first non-thought image of a successful response. A refusal
/// is a failure, not an error.
pub fn decodeImage(gpa: Allocator, arena: Allocator, body: []const u8) error{ BadResponse, OutOfMemory }!Decoded {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const parsed = std.json.parseFromSliceLeaky(Body, scratch.allocator(), body, .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.BadResponse,
    };
    if (parsed.promptFeedback) |f| if (f.blockReason) |r| {
        return .{ .failure = .{ .code = "content_policy", .message = try std.fmt.allocPrint(arena, "prompt blocked: {s}", .{r}) } };
    };
    const candidates = parsed.candidates orelse return error.BadResponse;
    if (candidates.len == 0) return error.BadResponse;
    const c = candidates[0];
    var text: ?[]const u8 = null;
    if (c.content) |content| if (content.parts) |parts| for (parts) |p| {
        if (p.thought orelse false) continue;
        if (p.inlineData orelse p.inline_data) |blob| {
            const decoder = std.base64.standard.Decoder;
            const len = decoder.calcSizeForSlice(blob.data) catch return error.BadResponse;
            const out = try gpa.alloc(u8, len);
            errdefer gpa.free(out);
            decoder.decode(out, blob.data) catch return error.BadResponse;
            return .{ .bytes = out };
        }
        if (p.text) |t| text = t;
    };
    const reason = c.finishReason orelse "none";
    const detail = if (text) |t| try std.fmt.allocPrint(arena, "{s}: {s}", .{ reason, t[0..@min(t.len, 300)] }) else try arena.dupe(u8, reason);
    for (policy_reasons) |r| if (std.mem.eql(u8, reason, r)) {
        return .{ .failure = .{ .code = "content_policy", .message = detail } };
    };
    return .{ .failure = .{ .code = "provider_error", .message = try std.fmt.allocPrint(arena, "no image returned ({s})", .{detail}) } };
}

/// Maps a non-2xx response. Errors look like
/// `{"error":{"code":400,"message":"…","status":"INVALID_ARGUMENT"}}`.
pub fn mapError(arena: Allocator, status: u16, body: []const u8) Allocator.Error!clikit.Failure {
    const B = struct { @"error": ?struct { message: ?[]const u8 = null, status: ?[]const u8 = null } = null };
    var message: []const u8 = std.mem.trim(u8, body, " \r\n\t");
    message = message[0..@min(message.len, 500)];
    if (std.json.parseFromSliceLeaky(B, arena, body, .{ .ignore_unknown_fields = true })) |b| {
        if (b.@"error") |e| if (e.message) |m| {
            message = m;
        };
    } else |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {},
    }
    if (message.len == 0) message = "empty response";
    const full = try std.fmt.allocPrint(arena, "HTTP {d}: {s}", .{ status, message });
    // An invalid key is a 400, not a 401.
    if (status == 401 or status == 403 or std.mem.indexOf(u8, message, "API key not valid") != null) return .{ .code = "auth", .message = full };
    if (status == 429) return .{ .code = "rate_limited", .message = full, .retryable = true };
    return .{ .code = "provider_error", .message = full, .retryable = status >= 500 };
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

test "request body" {
    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeBody(&w, .{
        .model = "m",
        .prompt = "make it \"blue\"",
        .aspect_ratio = "16:9",
        .image_size = "2K",
        .images = &.{.{ .data = "abc", .format = .jpeg }},
    });
    try testing.expectEqualStrings(
        \\{"contents":[{"role":"user","parts":[{"text":"make it \"blue\""},{"inlineData":{"mimeType":"image/jpeg","data":"YWJj"}}]}],"generationConfig":{"responseModalities":["IMAGE"],"imageConfig":{"aspectRatio":"16:9","imageSize":"2K"}}}
    , w.buffered());

    w = .fixed(&buf);
    try writeBody(&w, .{ .model = "m", .prompt = "p" });
    try testing.expectEqualStrings(
        \\{"contents":[{"role":"user","parts":[{"text":"p"}]}],"generationConfig":{"responseModalities":["IMAGE"]}}
    , w.buffered());
}

test "aspect ratio mapping" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exact = try imageConfig(a, "gemini-3-pro-image", 16, 9, false);
    try testing.expectEqualStrings("16:9", exact.aspect_ratio);
    try testing.expectEqual(null, exact.warning);
    try testing.expectEqualStrings("21:9", (try imageConfig(a, "gemini-3-pro-image", 4, 1, false)).aspect_ratio);
    try testing.expectEqualStrings("4:1", (try imageConfig(a, "gemini-nano-banana-2.1", 4, 1, false)).aspect_ratio);
    const sized = try imageConfig(a, "gemini-nano-banana-2.1", 1920, 1080, true);
    try testing.expectEqualStrings("16:9", sized.aspect_ratio);
    try testing.expectEqualStrings("2K", sized.image_size.?);
    try testing.expectEqual(null, (try imageConfig(a, "gemini-2.5-flash-image", 1920, 1080, true)).image_size);
}

test "decode image and refusals" {
    const gpa = testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const ok = try decodeImage(gpa, a,
        \\{"candidates":[{"content":{"role":"model","parts":[{"text":"thinking","thought":true},{"inlineData":{"mimeType":"image/png","data":"eA==","thought":true},"thought":true},{"text":"Here you go"},{"inlineData":{"mimeType":"image/png","data":"aGVsbG8="}}]},"finishReason":"STOP"}],"usageMetadata":{}}
    );
    defer gpa.free(ok.bytes);
    try testing.expectEqualStrings("hello", ok.bytes);

    const blocked = try decodeImage(gpa, a, "{\"promptFeedback\":{\"blockReason\":\"PROHIBITED_CONTENT\"}}");
    try testing.expectEqualStrings("content_policy", blocked.failure.code);

    const unsafe = try decodeImage(gpa, a, "{\"candidates\":[{\"finishReason\":\"IMAGE_SAFETY\"}]}");
    try testing.expectEqualStrings("content_policy", unsafe.failure.code);

    const none = try decodeImage(gpa, a, "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"I can only describe it.\"}]},\"finishReason\":\"NO_IMAGE\"}]}");
    try testing.expectEqualStrings("provider_error", none.failure.code);
    try testing.expectEqualStrings("no image returned (NO_IMAGE: I can only describe it.)", none.failure.message);

    try testing.expectError(error.BadResponse, decodeImage(gpa, a, "<html>"));
}

test "map errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad_key = try mapError(a, 400, "{\"error\":{\"code\":400,\"message\":\"API key not valid. Please pass a valid API key.\",\"status\":\"INVALID_ARGUMENT\"}}");
    try testing.expectEqualStrings("auth", bad_key.code);
    const quota = try mapError(a, 429, "{\"error\":{\"code\":429,\"message\":\"Resource exhausted\",\"status\":\"RESOURCE_EXHAUSTED\"}}");
    try testing.expectEqualStrings("rate_limited", quota.code);
    try testing.expectEqualStrings("HTTP 429: Resource exhausted", quota.message);
    try testing.expect((try mapError(a, 503, "")).retryable);
}
