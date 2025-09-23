const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "pishleme",
        .root_module = b.addModule("pishleme", .{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibC();
    b.installArtifact(exe);

    // Add x86_64 target for Intel Macs
    const x86_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .macos,
    });

    const exe_x86 = b.addExecutable(.{
        .name = "pishleme-x86_64",
        .root_module = b.addModule("pishleme-x86", .{
            .root_source_file = b.path("src/main.zig"),
            .target = x86_target,
            .optimize = optimize,
        }),
    });
    exe_x86.linkLibC();

    const install_x86 = b.addInstallArtifact(exe_x86, .{});
    const x86_step = b.step("x86", "Build for x86_64 (Intel Macs)");
    x86_step.dependOn(&install_x86.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
