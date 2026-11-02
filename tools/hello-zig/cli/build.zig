const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Injected by `go run ./cmd/repo build`; a plain `zig build` reports "dev".
    const options = b.addOptions();
    options.addOption([]const u8, "version", b.option([]const u8, "version", "Release version") orelse "dev");
    options.addOption([]const u8, "commit", b.option([]const u8, "commit", "Git commit") orelse "");
    options.addOption([]const u8, "date", b.option([]const u8, "date", "Commit date") orelse "");

    const strip = b.option(bool, "strip", "Strip debug info") orelse false;

    const clikit = b.dependency("clikit", .{ .target = target, .optimize = optimize });
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "clikit", .module = clikit.module("clikit") },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });

    const exe = b.addExecutable(.{ .name = "hello-zig", .root_module = root_module });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPassthruArgs();
    b.step("run", "Run the CLI").dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root_module });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
}
