const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    //const optimize = b.standardOptimizeOption(.{}); // -O Debug
    const optimize = std.builtin.OptimizeMode.ReleaseFast; // -O ReleaseFast
    
    const zzz = b.addModule("zzz", .{
        .root_source_file = b.path("src/lib.zig"),
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

    const all_http_examples_step = b.step("examples_http", "Build all HTTP examples");
    add_http_example(b, all_http_examples_step, "basic", false, target, optimize, zzz);
    add_http_example(b, all_http_examples_step, "cookies", false, target, optimize, zzz);
    add_http_example(b, all_http_examples_step, "form", false, target, optimize, zzz);
    add_http_example(b, all_http_examples_step, "fs", false, target, optimize, zzz);
    add_http_example(b, all_http_examples_step, "middleware", false, target, optimize, zzz);
    add_http_example(b, all_http_examples_step, "sse", false, target, optimize, zzz);
    add_http_example(b, all_http_examples_step, "tls", true, target, optimize, zzz);
    add_http_example(b, all_http_examples_step, "rest", false, target, optimize, zzz);

    if (target.result.os.tag != .windows) {
        add_http_example(b, all_http_examples_step, "unix", false, target, optimize, zzz);
    }
    
    
    
    const example1_ws_step = b.step("ex_ws_1", "Build ws example1");
    const example2_ws_step = b.step("ex_ws_2", "Build ws example2");
    const example3_ws_step = b.step("ex_ws_3", "Build ws example3");
    const example4_ws_step = b.step("ex_ws_4", "Build ws example4");
    
    const exe_ws1 = b.addExecutable(.{ // without C libs
      .name = "ex_ws_1", // exe name
      .root_source_file = b.path("examples_ws/example_ws_1.zig"), // b.path("src/test1.zig"), // main file
      .target = target,
      .optimize = optimize,
    });
    const exe_ws2 = b.addExecutable(.{ // without C libs
      .name = "ex_ws_2", // exe name
      .root_source_file = b.path("examples_ws/example_ws_2.zig"), // main file
      .target = target,
      .optimize = optimize,
    });
    const exe_ws3 = b.addExecutable(.{ // without C libs
      .name = "ex_ws_3", // exe name
      .root_source_file = b.path("examples_ws/example_ws_3.zig"), // main file
      .target = target,
      .optimize = optimize,
    });
    const exe_ws4 = b.addExecutable(.{ // without C libs
      .name = "ex_ws_4", // exe name
      .root_source_file = b.path("examples_ws/example_ws_4.zig"), // main file
      .target = target,
      .optimize = optimize,
    });
    
    exe_ws1.root_module.addImport("zzz", zzz);
    exe_ws2.root_module.addImport("zzz", zzz);
    exe_ws3.root_module.addImport("zzz", zzz);
    exe_ws4.root_module.addImport("zzz", zzz);
    
    const install_ws1 = b.addInstallBinFile(exe_ws1.getEmittedBin(), "../../ex_ws_1"); // b.addInstallBinFile(exe_ws1.getEmittedBin(), "ex_ws_1"); // -femit-bin=ex_ws_1 // to project root
    b.getInstallStep().dependOn(&install_ws1.step);
    example1_ws_step.dependOn(&install_ws1.step);
    const install_ws2 = b.addInstallBinFile(exe_ws2.getEmittedBin(), "../../ex_ws_2"); // to project root
    b.getInstallStep().dependOn(&install_ws2.step);
    example2_ws_step.dependOn(&install_ws2.step);
    const install_ws3 = b.addInstallBinFile(exe_ws3.getEmittedBin(), "../../ex_ws_3"); // to project root
    b.getInstallStep().dependOn(&install_ws3.step);
    example3_ws_step.dependOn(&install_ws3.step);
    const install_ws4 = b.addInstallBinFile(exe_ws4.getEmittedBin(), "../../ex_ws_4"); // to project root
    b.getInstallStep().dependOn(&install_ws4.step);
    example4_ws_step.dependOn(&install_ws4.step);
    b.default_step = b.getInstallStep();
    //b.installArtifact(exe_test1); // saves to /zig-out/bin/test1
    
    const all_ws_examples_step = b.step("examples_ws", "Build all WS examples");
    all_ws_examples_step.dependOn(&install_ws1.step);
    all_ws_examples_step.dependOn(&install_ws2.step);
    all_ws_examples_step.dependOn(&install_ws3.step);
    all_ws_examples_step.dependOn(&install_ws4.step);
    
    
    const tests = b.addTest(.{
        .name = "tests",
        .root_source_file = b.path("./src/tests.zig"),
    });
    tests.root_module.addImport("tardy", tardy);
    tests.root_module.addImport("secsock", secsock);

    const run_test = b.addRunArtifact(tests);
    run_test.step.dependOn(&tests.step);

    const test_step = b.step("test", "Run general unit tests");
    test_step.dependOn(&run_test.step);
}

fn add_http_example(
    b: *std.Build,
    all_http_examples_step: *std.Build.Step,
    name: []const u8,
    link_libc: bool,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
    zzz_module: *std.Build.Module,
) void {
    const example = b.addExecutable(.{
        .name = name,
        .root_source_file = b.path(b.fmt("./examples_http/{s}/main.zig", .{name})),
        .target = target,
        .optimize = optimize,
        .strip = false,
    });

    if (link_libc) {
        example.linkLibC();
    }

    example.root_module.addImport("zzz", zzz_module);

    //const install_artifact = b.addInstallArtifact(example, .{});
    const install_artifact = b.addInstallBinFile(example.getEmittedBin(), b.fmt("../../{s}", .{name})); //  to project root
    b.getInstallStep().dependOn(&install_artifact.step);

    all_http_examples_step.dependOn(&install_artifact.step);

    const build_step = b.step(b.fmt("{s}", .{name}), b.fmt("Build zzz example ({s})", .{name}));
    build_step.dependOn(&install_artifact.step);

    const run_artifact = b.addRunArtifact(example);
    run_artifact.step.dependOn(&install_artifact.step);

    const run_step = b.step(b.fmt("run_{s}", .{name}), b.fmt("Run zzz example ({s})", .{name}));
    run_step.dependOn(&install_artifact.step);
    run_step.dependOn(&run_artifact.step);
}

