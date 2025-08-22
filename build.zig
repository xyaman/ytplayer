const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ytplayer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const mibu_dep = b.dependency("mibu", .{});
    exe.root_module.addImport("mibu", mibu_dep.module("mibu"));

    const pa_c_dep = b.dependency("portaudio", .{
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibrary(pa_c_dep.artifact("portaudio"));

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
}
