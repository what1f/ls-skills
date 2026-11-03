//! `imgen providers`: built-in and configured providers, whether their
//! credentials are present, and what their known models can do.
const std = @import("std");
const clikit = @import("clikit");
const Ctx = @import("../ctx.zig").Ctx;
const provider = @import("../provider.zig");

pub const usage =
    \\List image providers, their credentials and model capabilities.
    \\
    \\Providers come built in (openai, gemini, codex) or from the config file
    \\shown as "config"; edit that JSON file to add OpenAI- or Gemini-compatible
    \\providers.
    \\
    \\Usage:
    \\  imgen providers [flags]
    \\
    \\Flags:
    \\  --format text|json   Output format (default text)
    \\
;

const ModelOut = struct {
    name: []const u8,
    edit: bool,
    mask: bool,
    native_transparent: bool,
    sizes: []const u8,
    output_format: bool,
    quality: bool,
    max_images: u8,

    fn from(name: []const u8, c: provider.Capabilities) ModelOut {
        return .{
            .name = name,
            .edit = c.edit,
            .mask = c.mask,
            .native_transparent = c.native_transparent,
            .sizes = @tagName(c.sizes),
            .output_format = c.output_format,
            .quality = c.quality,
            .max_images = c.max_images,
        };
    }
};

const ProviderOut = struct {
    name: []const u8,
    source: []const u8,
    protocol: []const u8,
    configured: bool,
    credential: []const u8,
    base_url: []const u8,
    edit_format: ?[]const u8,
    default_model: []const u8,
    models: []const ModelOut,
};

pub fn run(ctx: Ctx, args: []const [:0]const u8) !u8 {
    var format: clikit.Format = .text;
    var it: clikit.ArgIterator = .{ .args = args };
    while (it.next()) |arg| {
        if (clikit.isHelp(arg)) {
            try ctx.stdout.writeAll(usage);
            return clikit.exit.ok;
        }
        const v = (it.value(arg, "--format") catch null) orelse
            return clikit.fail(ctx.stdout, ctx.stderr, clikit.scanFormat(args), .{ .code = "usage", .message = "unknown argument (see --help)" }, clikit.exit.usage);
        format = clikit.Format.parse(v) orelse
            return clikit.fail(ctx.stdout, ctx.stderr, .text, .{ .code = "usage", .message = "--format must be text or json" }, clikit.exit.usage);
    }

    const a = ctx.arena;
    var problem: []const u8 = "";
    const reg = provider.load(ctx.io, a, ctx.env, &problem) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.ConfigInvalid => return clikit.fail(ctx.stdout, ctx.stderr, format, .{ .code = "config", .message = problem }, clikit.exit.usage),
    };

    const list = try a.alloc(ProviderOut, reg.providers.len);
    for (reg.providers, list) |p, *out| {
        const models = try a.alloc(ModelOut, p.models.len);
        for (p.models, models) |m, *mo| mo.* = .from(m.name, m.caps);
        out.* = .{
            .name = p.name,
            .source = @tagName(p.source),
            .protocol = @tagName(p.protocol),
            .configured = try provider.hasCredential(ctx.io, a, p, ctx.env),
            .credential = try provider.credentialSource(a, p, ctx.env),
            .base_url = p.base_url,
            .edit_format = if (p.protocol == .openai) @tagName(p.edit_format) else null,
            .default_model = p.default_model,
            .models = models,
        };
    }
    const selected = try provider.defaultSelection(ctx.io, a, reg, ctx.env);

    switch (format) {
        .json => try clikit.writeOk(ctx.stdout, .{
            .config = reg.config_path,
            .config_found = reg.config_found,
            .selected = if (selected) |s| try std.fmt.allocPrint(a, "{s}/{s}", .{ s.provider.name, s.model }) else null,
            .providers = list,
        }),
        .text => {
            for (list) |p| {
                const mark = if (selected != null and std.mem.eql(u8, selected.?.provider.name, p.name)) "*" else " ";
                const state = if (p.configured) "ready" else "no credential";
                const model = if (selected != null and std.mem.eql(u8, selected.?.provider.name, p.name)) selected.?.model else p.default_model;
                try ctx.stdout.print("{s} {s:<12} {s:<18} {s:<24} {s}\n", .{ mark, p.name, state, model, p.credential });
            }
            try ctx.stdout.print("\nconfig: {s}{s}\n", .{ reg.config_path, if (reg.config_found) "" else " (not created)" });
        },
    }
    return clikit.exit.ok;
}

test "providers json" {
    var t: @import("../ctx.zig").TestCtx = undefined;
    try t.init();
    defer t.deinit();
    try t.env.put("CODEX_HOME", "/nonexistent-imgen");
    try std.testing.expectEqual(clikit.exit.ok, try run(t.ctx(), &.{ "--format", "json" }));
    const out = t.out.written();
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"ok\":true,\"data\":{\"config\":\"/nonexistent-imgen/config.json\",\"config_found\":false,\"selected\":null,"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\"credential\":\"/nonexistent-imgen/auth.json\"") != null);
}
