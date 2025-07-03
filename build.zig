const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Sequential version
    const exe = b.addExecutable(.{
        .name = "rss-cache-parser",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Parallel version
    const parallel_exe = b.addExecutable(.{
        .name = "rss-cache-parser-parallel",
        .root_source_file = b.path("src/parallel_main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);
    b.installArtifact(parallel_exe);

    // Run commands
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_parallel_cmd = b.addRunArtifact(parallel_exe);
    run_parallel_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
        run_parallel_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the sequential version");
    run_step.dependOn(&run_cmd.step);

    const run_parallel_step = b.step("run-parallel", "Run the parallel version");
    run_parallel_step.dependOn(&run_parallel_cmd.step);
}