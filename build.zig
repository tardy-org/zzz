pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const secsock = b.dependency("secsock", .{
        .target = target,
        .optimize = optimize,
    }).module("secsock");

    const tardy = secsock.import_table.get("tardy").?;

    const zzz = b.addModule("zzz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tardy", .module = tardy },
            .{ .name = "secsock", .module = secsock },
        },
    });

    const all = b.step("all", "Build all Zzz examples");

    for ([_][]const u8{
        "basic",
        "cookies",
        "form",
        "fs",
        "middleware",
        "sse",
        "tls",
    }) |name| add_example(b, .{
        .name = name,
        .target = target,
        .optimize = optimize,
        .zzz_module = zzz,
        .all = all,
    });

    if (target.result.os.tag != .windows) add_example(b, .{
        .name = "unix",
        .target = target,
        .optimize = optimize,
        .zzz_module = zzz,
        .all = all,
    });

    const tests = b.addTest(.{
        .name = "tests",
        .root_module = b.addModule("tests", .{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_test = b.addRunArtifact(tests);
    run_test.step.dependOn(&tests.step);

    const test_step = b.step("test", "Run general unit tests");
    test_step.dependOn(&run_test.step);
}

fn add_example(
    b: *Build,
    options: struct {
        name: []const u8,
        target: Build.ResolvedTarget,
        optimize: std.lang.Optimize,
        zzz_module: *Build.Module,
        all: *Build.Step,
    },
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(
            b.fmt("examples/{s}/main.zig", .{options.name}),
        ),
        .optimize = options.optimize,
        .target = options.target,
        .strip = false,
    });
    mod.addImport("zzz", options.zzz_module);

    const example = b.addExecutable(.{
        .name = options.name,
        .root_module = mod,
    });

    const install_artifact = b.addInstallArtifact(
        example,
        .{},
    );
    options.all.dependOn(&install_artifact.step);

    const build_step = b.step(
        b.fmt("{s}", .{options.name}),
        b.fmt("Build zzz example ({s})", .{options.name}),
    );
    build_step.dependOn(&install_artifact.step);

    const run_artifact = b.addRunArtifact(example);
    run_artifact.step.dependOn(&install_artifact.step);

    const run_step = b.step(
        b.fmt("run_{s}", .{options.name}),
        b.fmt("Run zzz example ({s})", .{options.name}),
    );
    run_step.dependOn(&install_artifact.step);
    run_step.dependOn(&run_artifact.step);
}

const std = @import("std");
const Build = std.Build;
