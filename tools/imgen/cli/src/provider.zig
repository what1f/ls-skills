//! Provider registry: built-in providers plus the ones declared in
//! config.json, how one is selected, and where its credential comes from.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;

pub const Protocol = enum { openai, gemini };

/// How an openai-protocol provider takes input images.
pub const EditFormat = enum { multipart, json };

/// How the requested aspect ratio reaches the model.
pub const Sizes = enum {
    /// Any WxH within limits; aspect ratios are mapped to a size.
    flexible,
    /// 1024x1024, 1536x1024 or 1024x1536.
    fixed,
    /// Size is ignored; the aspect ratio is written into the prompt.
    prompt,
    /// A fixed list of aspect ratios plus size tiers (Gemini).
    ratio,
};

pub const Capabilities = struct {
    edit: bool,
    mask: bool,
    native_transparent: bool,
    sizes: Sizes,
    /// False when the provider always returns PNG.
    output_format: bool,
    quality: bool,
    max_images: u8,
};

pub const Auth = union(enum) {
    none,
    /// First non-empty variable wins; sent as a Bearer token.
    env: []const []const u8,
    /// Shell command whose trimmed stdout is the key.
    command: []const u8,
    /// Codex ChatGPT login in $CODEX_HOME/auth.json.
    codex_login,
};

pub const Model = struct {
    name: []const u8,
    caps: Capabilities,
};

pub const Provider = struct {
    name: []const u8,
    source: enum { builtin, config },
    protocol: Protocol,
    base_url: []const u8,
    auth: Auth,
    edit_format: EditFormat,
    default_model: []const u8,
    /// Capabilities assumed for model names not listed in `models`.
    default_caps: Capabilities,
    models: []const Model,

    pub fn caps(p: Provider, model: []const u8) Capabilities {
        for (p.models) |m| if (std.mem.eql(u8, m.name, model)) return m.caps;
        return p.default_caps;
    }
};

fn protocolCaps(protocol: Protocol) Capabilities {
    return switch (protocol) {
        .openai => .{ .edit = true, .mask = true, .native_transparent = false, .sizes = .flexible, .output_format = true, .quality = true, .max_images = 16 },
        .gemini => .{ .edit = true, .mask = false, .native_transparent = false, .sizes = .ratio, .output_format = false, .quality = false, .max_images = 14 },
    };
}

// gpt-image-1.x: three fixed sizes, native transparency.
const gpt_image_1_caps: Capabilities = .{ .edit = true, .mask = true, .native_transparent = true, .sizes = .fixed, .output_format = true, .quality = true, .max_images = 16 };

// The Codex backend ignores `size` and `output_format`: it always returns PNG
// and picks dimensions from the prompt.
const codex_caps: Capabilities = .{ .edit = true, .mask = true, .native_transparent = true, .sizes = .prompt, .output_format = false, .quality = true, .max_images = 16 };

// Module-level so the slices outlive builtins().
const openai_models = [_]Model{
    .{ .name = "gpt-image-2", .caps = protocolCaps(.openai) },
    .{ .name = "gpt-image-1.5", .caps = gpt_image_1_caps },
    .{ .name = "gpt-image-1", .caps = gpt_image_1_caps },
    .{ .name = "gpt-image-1-mini", .caps = gpt_image_1_caps },
};

// https://ai.google.dev/gemini-api/docs/image-generation (2026-11)
const gemini_models = [_]Model{
    .{ .name = "gemini-nano-banana-2.1", .caps = protocolCaps(.gemini) },
    .{ .name = "gemini-3.1-flash-image", .caps = protocolCaps(.gemini) },
    .{ .name = "gemini-3.1-flash-lite-image", .caps = protocolCaps(.gemini) },
    .{ .name = "gemini-3-pro-image", .caps = protocolCaps(.gemini) },
    .{ .name = "gemini-2.5-flash-image", .caps = blk: {
        var c = protocolCaps(.gemini);
        c.max_images = 3;
        break :blk c;
    } },
};

const codex_models = [_]Model{
    .{ .name = "gpt-image-2.5-flare", .caps = codex_caps },
    .{ .name = "gpt-image-2.5-sunburst", .caps = codex_caps },
};

fn builtins(arena: Allocator, env: *const Environ.Map) Allocator.Error![]Provider {
    const list = try arena.alloc(Provider, 3);
    list[0] = .{
        .name = "openai",
        .source = .builtin,
        .protocol = .openai,
        .base_url = envUrl(env, "OPENAI_BASE_URL") orelse "https://api.openai.com/v1",
        .auth = .{ .env = &.{"OPENAI_API_KEY"} },
        .edit_format = .multipart,
        .default_model = "gpt-image-2",
        .default_caps = protocolCaps(.openai),
        .models = &openai_models,
    };
    list[1] = .{
        .name = "gemini",
        .source = .builtin,
        .protocol = .gemini,
        .base_url = envUrl(env, "GEMINI_BASE_URL") orelse "https://generativelanguage.googleapis.com",
        .auth = .{ .env = &.{ "GEMINI_API_KEY", "GOOGLE_API_KEY" } },
        .edit_format = .json,
        .default_model = "gemini-nano-banana-2.1",
        .default_caps = protocolCaps(.gemini),
        .models = &gemini_models,
    };
    list[2] = .{
        .name = "codex",
        .source = .builtin,
        .protocol = .openai,
        .base_url = "https://chatgpt.com/backend-api/codex",
        .auth = .codex_login,
        .edit_format = .json,
        .default_model = "gpt-image-2.5-flare",
        .default_caps = codex_caps,
        .models = &codex_models,
    };
    return list;
}

fn envUrl(env: *const Environ.Map, name: []const u8) ?[]const u8 {
    return if (nonEmpty(env, name)) |v| std.mem.trimEnd(u8, v, "/") else null;
}

// ---------------------------------------------------------------------------
// config.json

const CapsConfig = struct {
    edit: ?bool = null,
    mask: ?bool = null,
    native_transparent: ?bool = null,
    sizes: ?Sizes = null,
    output_format: ?bool = null,
    quality: ?bool = null,
    max_images: ?u8 = null,

    fn apply(c: CapsConfig, base: Capabilities) Capabilities {
        var out = base;
        inline for (comptime std.meta.fieldNames(Capabilities)) |f| {
            if (@field(c, f)) |v| @field(out, f) = v;
        }
        return out;
    }
};

const ProviderConfig = struct {
    protocol: ?Protocol = null,
    base_url: ?[]const u8 = null,
    api_key_env: ?[]const u8 = null,
    api_key_command: ?[]const u8 = null,
    edit_format: ?EditFormat = null,
    default_model: ?[]const u8 = null,
    capabilities: ?CapsConfig = null,
    models: ?std.json.ArrayHashMap(CapsConfig) = null,
};

const Config = struct {
    @"$schema": ?[]const u8 = null,
    default: ?[]const u8 = null,
    providers: ?std.json.ArrayHashMap(ProviderConfig) = null,
};

pub const Registry = struct {
    providers: []const Provider,
    /// `default` from config.json: "provider", "provider/model" or "model".
    default: ?[]const u8 = null,
    config_path: []const u8,
    config_found: bool = false,

    pub fn get(r: Registry, name: []const u8) ?*const Provider {
        for (r.providers) |*p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }
};

/// `$IMGEN_CONFIG`, else `$XDG_CONFIG_HOME/imgen/config.json`, else
/// `~/.config/imgen/config.json` (`%APPDATA%\imgen\config.json` on Windows).
pub fn configPath(arena: Allocator, env: *const Environ.Map) Allocator.Error![]const u8 {
    if (nonEmpty(env, "IMGEN_CONFIG")) |p| return p;
    if (nonEmpty(env, "XDG_CONFIG_HOME")) |d| return std.fs.path.join(arena, &.{ d, "imgen", "config.json" });
    if (@import("builtin").os.tag == .windows) {
        if (nonEmpty(env, "APPDATA")) |d| return std.fs.path.join(arena, &.{ d, "imgen", "config.json" });
    }
    return std.fs.path.join(arena, &.{ home(env), ".config", "imgen", "config.json" });
}

fn home(env: *const Environ.Map) []const u8 {
    return nonEmpty(env, "HOME") orelse nonEmpty(env, "USERPROFILE") orelse ".";
}

pub const LoadError = error{ConfigInvalid} || Allocator.Error;

/// Builds the registry. A missing config file is fine; an invalid one is
/// `error.ConfigInvalid` with the reason in `problem`.
pub fn load(io: Io, arena: Allocator, env: *const Environ.Map, problem: *[]const u8) LoadError!Registry {
    const path = try configPath(arena, env);
    const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.FileNotFound => return .{ .providers = try builtins(arena, env), .config_path = path },
        else => {
            problem.* = try std.fmt.allocPrint(arena, "{s}: cannot read ({s})", .{ path, @errorName(err) });
            return error.ConfigInvalid;
        },
    };
    var reg = try fromConfig(arena, env, data, path, problem);
    reg.config_found = true;
    return reg;
}

fn fromConfig(arena: Allocator, env: *const Environ.Map, data: []const u8, path: []const u8, problem: *[]const u8) LoadError!Registry {
    var scanner: std.json.Scanner = .initCompleteInput(arena, data);
    var diag: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diag);
    const cfg = std.json.parseFromTokenSourceLeaky(Config, arena, &scanner, .{ .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => {
            problem.* = try std.fmt.allocPrint(arena, "{s}:{d}:{d}: {s}", .{ path, diag.getLine(), diag.getColumn(), jsonErrorText(err) });
            return error.ConfigInvalid;
        },
    };

    var list: std.ArrayList(Provider) = .empty;
    try list.appendSlice(arena, try builtins(arena, env));
    if (cfg.providers) |providers| {
        var it = providers.map.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (!validName(name)) {
                problem.* = try std.fmt.allocPrint(arena, "{s}: provider name \"{s}\" may only use letters, digits, '-' and '_'", .{ path, name });
                return error.ConfigInvalid;
            }
            const existing: ?*Provider = for (list.items) |*p| {
                if (std.mem.eql(u8, p.name, name)) break p;
            } else null;
            const merged = merge(arena, existing, name, entry.value_ptr.*, path, problem) catch |err| return err;
            if (existing) |p| p.* = merged else try list.append(arena, merged);
        }
    }
    return .{ .providers = list.items, .default = cfg.default, .config_path = path };
}

fn merge(arena: Allocator, base: ?*const Provider, name: []const u8, c: ProviderConfig, path: []const u8, problem: *[]const u8) LoadError!Provider {
    const fail = struct {
        fn f(a: Allocator, p: *[]const u8, cfg_path: []const u8, n: []const u8, comptime msg: []const u8) LoadError {
            p.* = try std.fmt.allocPrint(a, "{s}: providers.{s}: " ++ msg, .{ cfg_path, n });
            return error.ConfigInvalid;
        }
    }.f;
    if (c.api_key_env != null and c.api_key_command != null) return fail(arena, problem, path, name, "set api_key_env or api_key_command, not both");

    const protocol = c.protocol orelse if (base) |b| b.protocol else .openai;
    if (base) |b| if (protocol != b.protocol) return fail(arena, problem, path, name, "cannot change the protocol of a built-in provider");
    var p: Provider = if (base) |b| b.* else .{
        .name = name,
        .source = .config,
        .protocol = protocol,
        .base_url = c.base_url orelse return fail(arena, problem, path, name, "base_url is required"),
        .auth = .none,
        .edit_format = if (protocol == .openai) .multipart else .json,
        .default_model = "",
        .default_caps = protocolCaps(protocol),
        .models = &.{},
    };
    p.source = .config;
    if (c.base_url) |u| p.base_url = std.mem.trimEnd(u8, u, "/");
    if (c.api_key_env) |e| p.auth = .{ .env = try arena.dupe([]const u8, &.{e}) };
    if (c.api_key_command) |cmd| p.auth = .{ .command = cmd };
    if (c.edit_format) |f| p.edit_format = f;
    if (c.capabilities) |caps| p.default_caps = caps.apply(p.default_caps);

    if (c.models) |models| {
        var list: std.ArrayList(Model) = .empty;
        try list.appendSlice(arena, p.models);
        var it = models.map.iterator();
        while (it.next()) |entry| {
            const caps = entry.value_ptr.apply(p.caps(entry.key_ptr.*));
            for (list.items) |*m| {
                if (std.mem.eql(u8, m.name, entry.key_ptr.*)) {
                    m.caps = caps;
                    break;
                }
            } else try list.append(arena, .{ .name = entry.key_ptr.*, .caps = caps });
        }
        p.models = list.items;
    }
    if (c.default_model) |m| p.default_model = m;
    if (p.default_model.len == 0) {
        if (p.models.len == 0) return fail(arena, problem, path, name, "set default_model or list models");
        p.default_model = p.models[0].name;
    }
    return p;
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

fn jsonErrorText(err: anyerror) []const u8 {
    return switch (err) {
        error.UnknownField => "unknown field",
        error.MissingField => "missing field",
        error.InvalidEnumTag => "unknown value",
        error.UnexpectedToken => "unexpected value",
        error.SyntaxError => "invalid JSON",
        error.UnexpectedEndOfInput => "unexpected end of file",
        error.DuplicateField => "duplicate field",
        else => @errorName(err),
    };
}

// ---------------------------------------------------------------------------
// Credentials

/// Human-readable credential source for messages and `providers`.
pub fn credentialSource(arena: Allocator, p: Provider, env: *const Environ.Map) Allocator.Error![]const u8 {
    return switch (p.auth) {
        .none => "none",
        .env => |names| for (names) |n| {
            if (nonEmpty(env, n) != null) break n;
        } else names[0],
        .command => |cmd| try std.fmt.allocPrint(arena, "command: {s}", .{cmd}),
        .codex_login => try codexAuthPath(arena, env),
    };
}

pub fn codexAuthPath(arena: Allocator, env: *const Environ.Map) Allocator.Error![]const u8 {
    if (nonEmpty(env, "CODEX_HOME")) |h| return std.fs.path.join(arena, &.{ h, "auth.json" });
    return std.fs.path.join(arena, &.{ home(env), ".codex", "auth.json" });
}

/// Cheap check: the credential exists. Does not run key commands.
pub fn hasCredential(io: Io, arena: Allocator, p: Provider, env: *const Environ.Map) Allocator.Error!bool {
    return switch (p.auth) {
        .none, .command => true,
        .env => |names| for (names) |n| {
            if (nonEmpty(env, n) != null) break true;
        } else false,
        .codex_login => blk: {
            Io.Dir.cwd().access(io, try codexAuthPath(arena, env), .{}) catch break :blk false;
            break :blk true;
        },
    };
}

pub const Credential = union(enum) {
    /// The key or token; null for `auth = none`.
    ok: ?[]const u8,
    /// Why it is missing, naming what the user should set or run.
    missing: []const u8,
};

/// Reads the credential. Never put the result in any output.
pub fn credential(io: Io, arena: Allocator, p: Provider, env: *const Environ.Map) Allocator.Error!Credential {
    switch (p.auth) {
        .none => return .{ .ok = null },
        .env => |names| {
            for (names) |n| if (nonEmpty(env, n)) |key| return .{ .ok = key };
            return .{ .missing = try std.fmt.allocPrint(arena, "{s} is not set (needed by provider {s})", .{ names[0], p.name }) };
        },
        .command => |cmd| {
            const key = runKeyCommand(io, arena, cmd) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.CommandFailed => return .{ .missing = try std.fmt.allocPrint(arena, "api_key_command of provider {s} failed or printed nothing", .{p.name}) },
            };
            return .{ .ok = key };
        },
        .codex_login => {
            const path = try codexAuthPath(arena, env);
            const token = @import("provider/codex.zig").readToken(io, arena, path) catch |err| return switch (err) {
                error.OutOfMemory => |e| e,
                error.NotLoggedIn => .{ .missing = try std.fmt.allocPrint(arena, "Codex login not found at {s}: run `codex login`", .{path}) },
                error.NoToken => .{ .missing = try std.fmt.allocPrint(arena, "{s} has no ChatGPT login: run `codex login` and sign in with ChatGPT", .{path}) },
            };
            return .{ .ok = token };
        },
    }
}

fn runKeyCommand(io: Io, arena: Allocator, cmd: []const u8) error{ CommandFailed, OutOfMemory }![]const u8 {
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd.exe", "/C", cmd }
    else
        &.{ "/bin/sh", "-c", cmd };
    const result = std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(64 << 10),
        .stderr_limit = .limited(64 << 10),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return error.CommandFailed,
    };
    if (!result.term.success()) return error.CommandFailed;
    const key = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (key.len == 0) return error.CommandFailed;
    return key;
}

// ---------------------------------------------------------------------------
// Selection

pub const Selection = struct {
    provider: *const Provider,
    model: []const u8,
};

pub const SelectError = error{
    /// Names a provider that is neither built in nor in config.json.
    UnknownProvider,
    /// --provider and the --model prefix disagree.
    Conflict,
    /// Nothing selected and no built-in provider has a credential.
    NoCredential,
} || Allocator.Error;

/// A "provider/model", "provider" or "model" reference.
const Ref = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

/// Splits on the first '/' when the prefix is a known provider, so model
/// names that contain '/' (e.g. "black-forest-labs/FLUX.1") still work.
fn splitRef(reg: Registry, s: ?[]const u8) Ref {
    const v = s orelse return .{};
    if (std.mem.indexOfScalar(u8, v, '/')) |i| {
        if (reg.get(v[0..i]) != null) return .{ .provider = v[0..i], .model = if (i + 1 < v.len) v[i + 1 ..] else null };
    } else if (reg.get(v) != null) return .{ .provider = v };
    return .{ .model = v };
}

/// Order: flags, then IMGEN_PROVIDER / IMGEN_MODEL, then config `default`,
/// then the first built-in provider with a credential. A layer's model only
/// applies when it names no provider or the chosen one. On error `failed`
/// holds the provider name the error is about.
pub fn select(
    io: Io,
    arena: Allocator,
    reg: Registry,
    env: *const Environ.Map,
    provider_flag: ?[]const u8,
    model_flag: ?[]const u8,
    failed: *[]const u8,
) SelectError!Selection {
    const flag_ref = splitRef(reg, model_flag);
    if (provider_flag) |p| if (flag_ref.provider) |q| if (!std.mem.eql(u8, p, q)) {
        failed.* = p;
        return error.Conflict;
    };
    const env_ref = splitRef(reg, nonEmpty(env, "IMGEN_MODEL"));
    const layers = [_]Ref{
        .{ .provider = provider_flag orelse flag_ref.provider, .model = flag_ref.model },
        .{ .provider = nonEmpty(env, "IMGEN_PROVIDER") orelse env_ref.provider, .model = env_ref.model },
        splitRef(reg, reg.default),
    };

    var chosen: ?[]const u8 = null;
    for (layers) |l| {
        if (chosen == null) chosen = l.provider orelse if (l.model) |m| byModel(m) else null;
        if (chosen != null) break;
    }
    if (chosen == null) chosen = try firstConfigured(io, arena, reg, env);
    const name = chosen.?;
    failed.* = name;
    const p = reg.get(name) orelse return error.UnknownProvider;

    const model = for (layers) |l| {
        const m = l.model orelse continue;
        if (l.provider == null or std.mem.eql(u8, l.provider.?, name)) break m;
    } else p.default_model;
    return .{ .provider = p, .model = model };
}

fn byModel(model: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, model, "gemini-")) return "gemini";
    return null;
}

fn firstConfigured(io: Io, arena: Allocator, reg: Registry, env: *const Environ.Map) SelectError![]const u8 {
    for (reg.providers) |p| {
        if (p.source == .builtin and try hasCredential(io, arena, p, env)) return p.name;
    }
    // A config-declared provider counts too, once nothing built in is set up.
    for (reg.providers) |p| {
        if (p.source == .config and p.auth != .command and try hasCredential(io, arena, p, env)) return p.name;
    }
    return error.NoCredential;
}

/// The provider `select` would pick with no flags, or null.
pub fn defaultSelection(io: Io, arena: Allocator, reg: Registry, env: *const Environ.Map) Allocator.Error!?Selection {
    var failed: []const u8 = "";
    return select(io, arena, reg, env, null, null, &failed) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        else => return null,
    };
}

pub fn nonEmpty(env: *const Environ.Map, name: []const u8) ?[]const u8 {
    const v = env.get(name) orelse return null;
    return if (v.len == 0) null else v;
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

const test_config =
    \\{
    \\  "default": "relay/flux-dev",
    \\  "providers": {
    \\    "relay": {
    \\      "base_url": "https://relay.example.com/v1/",
    \\      "api_key_env": "RELAY_KEY",
    \\      "capabilities": { "mask": false },
    \\      "models": { "flux-dev": { "edit": false, "sizes": "fixed" }, "org/model": {} }
    \\    },
    \\    "openai": { "base_url": "https://proxy.example.com/v1", "models": { "gpt-image-2": { "native_transparent": true } } }
    \\  }
    \\}
;

const TestEnv = struct {
    arena: std.heap.ArenaAllocator,
    env: Environ.Map,

    fn init(t: *TestEnv) void {
        t.* = .{ .arena = .init(testing.allocator), .env = .init(testing.allocator) };
    }

    fn deinit(t: *TestEnv) void {
        t.env.deinit();
        t.arena.deinit();
    }

    fn registry(t: *TestEnv, config: []const u8) !Registry {
        var problem: []const u8 = "";
        return fromConfig(t.arena.allocator(), &t.env, config, "config.json", &problem);
    }
};

test "config adds and overrides providers" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    const reg = try t.registry(test_config);

    const relay = reg.get("relay").?;
    try testing.expectEqualStrings("https://relay.example.com/v1", relay.base_url);
    try testing.expectEqual(EditFormat.multipart, relay.edit_format);
    try testing.expectEqualStrings("flux-dev", relay.default_model);
    try testing.expect(!relay.caps("flux-dev").edit);
    try testing.expectEqual(Sizes.fixed, relay.caps("flux-dev").sizes);
    try testing.expect(!relay.caps("unknown").mask);

    const openai = reg.get("openai").?;
    try testing.expectEqualStrings("https://proxy.example.com/v1", openai.base_url);
    try testing.expect(openai.caps("gpt-image-2").native_transparent);
    try testing.expectEqual(Sizes.fixed, openai.caps("gpt-image-1.5").sizes);
    try testing.expectEqualStrings("OPENAI_API_KEY", openai.auth.env[0]);
}

test "config errors name the problem" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    var problem: []const u8 = "";
    const a = t.arena.allocator();
    try testing.expectError(error.ConfigInvalid, fromConfig(a, &t.env, "{\"providers\":{\"x\":{\"api_key_env\":\"K\"}}}", "c.json", &problem));
    try testing.expectEqualStrings("c.json: providers.x: base_url is required", problem);
    try testing.expectError(error.ConfigInvalid, fromConfig(a, &t.env, "{\n  \"providers\": {\"x\": {\"base_urll\": \"u\"}}}", "c.json", &problem));
    try testing.expect(std.mem.startsWith(u8, problem, "c.json:2:"));
    try testing.expect(std.mem.endsWith(u8, problem, "unknown field"));
}

test "selection order" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const reg = try t.registry(test_config);
    var failed: []const u8 = "";

    // config default
    var s = try select(testing.io, a, reg, &t.env, null, null, &failed);
    try testing.expectEqualStrings("relay", s.provider.name);
    try testing.expectEqualStrings("flux-dev", s.model);

    // env beats config; a model with a different provider prefix is ignored
    try t.env.put("IMGEN_PROVIDER", "codex");
    s = try select(testing.io, a, reg, &t.env, null, null, &failed);
    try testing.expectEqualStrings("codex", s.provider.name);
    try testing.expectEqualStrings("gpt-image-2.5-flare", s.model);

    // provider/model in a flag; model names may contain '/'
    s = try select(testing.io, a, reg, &t.env, null, "relay/org/model", &failed);
    try testing.expectEqualStrings("relay", s.provider.name);
    try testing.expectEqualStrings("org/model", s.model);

    // bare model with the env provider
    s = try select(testing.io, a, reg, &t.env, null, "gpt-image-2.5-sunburst", &failed);
    try testing.expectEqualStrings("codex", s.provider.name);
    try testing.expectEqualStrings("gpt-image-2.5-sunburst", s.model);

    try testing.expectError(error.Conflict, select(testing.io, a, reg, &t.env, "openai", "relay/flux-dev", &failed));
    try testing.expectError(error.UnknownProvider, select(testing.io, a, reg, &t.env, "nope", null, &failed));
    s = try select(testing.io, a, reg, &t.env, null, "gemini-3-pro-image", &failed);
    try testing.expectEqualStrings("gemini", s.provider.name);
}

test "nothing configured" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    try t.env.put("CODEX_HOME", "/nonexistent-imgen-test");
    const reg = try t.registry("{}");
    var failed: []const u8 = "";
    try testing.expectError(error.NoCredential, select(testing.io, t.arena.allocator(), reg, &t.env, null, null, &failed));
}

test "credential from env and command" {
    var t: TestEnv = undefined;
    t.init();
    defer t.deinit();
    const a = t.arena.allocator();
    const reg = try t.registry(test_config);
    const relay = reg.get("relay").?.*;
    try testing.expect((try credential(testing.io, a, relay, &t.env)) == .missing);
    try t.env.put("RELAY_KEY", "k1");
    try testing.expectEqualStrings("k1", (try credential(testing.io, a, relay, &t.env)).ok.?);

    if (@import("builtin").os.tag != .windows) {
        var cmd = relay;
        cmd.auth = .{ .command = "printf ' k2\\n'" };
        try testing.expectEqualStrings("k2", (try credential(testing.io, a, cmd, &t.env)).ok.?);
        cmd.auth = .{ .command = "exit 1" };
        try testing.expect((try credential(testing.io, a, cmd, &t.env)) == .missing);
    }
}
