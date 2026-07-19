const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zzz = b.addModule("zzz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tardy = b.dependency("tardy", .{
        .target = target,
        .optimize = optimize,
    }).module("tardy");

    zzz.addImport("tardy", tardy);

    const secsock = b.dependency("secsock", .{
        .target = target,
        .optimize = optimize,
    }).module("secsock");

    zzz.addImport("secsock", secsock);

    for ([_][]const u8{
        "basic",
        "cookies",
        "form",
        "fs",
        "middleware",
        "sse",
        "tls",
    }) |name| add_example(
        b,
        name,
        target,
        optimize,
        zzz,
    );

    if (target.result.os.tag != .windows) add_example(
        b,
        "unix",
        target,
        optimize,
        zzz,
    );

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
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zzz_module: *std.Build.Module,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
        .optimize = optimize,
        .target = target,
        .strip = false,
    });
    mod.addImport("zzz", zzz_module);

    const example = b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });

    const install_artifact = b.addInstallArtifact(example, .{});
    b.getInstallStep().dependOn(&install_artifact.step);

    const build_step = b.step(
        b.fmt("{s}", .{name}),
        b.fmt("Build zzz example ({s})", .{name}),
    );
    build_step.dependOn(&install_artifact.step);

    const run_artifact = b.addRunArtifact(example);
    run_artifact.step.dependOn(&install_artifact.step);

    const run_step = b.step(
        b.fmt("run_{s}", .{name}),
        b.fmt("Run zzz example ({s})", .{name}),
    );
    run_step.dependOn(&install_artifact.step);
    run_step.dependOn(&run_artifact.step);
}
