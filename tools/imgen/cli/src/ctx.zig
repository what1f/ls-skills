//! What every command gets from main.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Ctx = struct {
    io: std.Io,
    /// Thread-safe; for large buffers that are freed early.
    gpa: Allocator,
    /// Thread-safe; lives until exit.
    arena: Allocator,
    env: *const std.process.Environ.Map,
    stdout: *Writer,
    stderr: *Writer,
};

/// A Ctx backed by in-memory writers and an empty environment.
pub const TestCtx = struct {
    arena: std.heap.ArenaAllocator,
    env: std.process.Environ.Map,
    out: Writer.Allocating,
    err: Writer.Allocating,

    pub fn init(t: *TestCtx) !void {
        const gpa = std.testing.allocator;
        t.* = .{
            .arena = .init(gpa),
            .env = .init(gpa),
            .out = .init(gpa),
            .err = .init(gpa),
        };
        // Keep the developer's real config out of tests.
        try t.env.put("IMGEN_CONFIG", "/nonexistent-imgen/config.json");
    }

    pub fn deinit(t: *TestCtx) void {
        t.err.deinit();
        t.out.deinit();
        t.env.deinit();
        t.arena.deinit();
    }

    pub fn ctx(t: *TestCtx) Ctx {
        return .{
            .io = std.testing.io,
            .gpa = std.testing.allocator,
            .arena = t.arena.allocator(),
            .env = &t.env,
            .stdout = &t.out.writer,
            .stderr = &t.err.writer,
        };
    }
};
