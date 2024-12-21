const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const program_name = if (target.query.os_tag == .macos) "yadl-mac" else if (target.query.os_tag == .windows) "yadl-win" else "yadl-linux";

    const exe = b.addExecutable(.{
        .name = program_name,
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/Parser.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_script_tests = b.addTest(.{
        .root_source_file = b.path("src/yadlSourceTesting.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const run_exe_script_tests = b.addRunArtifact(exe_script_tests);

    const test_step = b.step("test", "Run unit and script tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_exe_script_tests.step);
}
