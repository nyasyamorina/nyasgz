const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nyasgz = b.addModule("nyasgz", .{
        .root_source_file = b.path("src/nyasgz.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "nyasgz-exe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nyasgz", .module = nyasgz },
            },
        }),
    });
    b.installArtifact(exe);

    // run
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // test
    const nyasgz_tests = b.addTest(.{
        .root_module = nyasgz,
    });
    const run_nyasgz_tests = b.addRunArtifact(nyasgz_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_nyasgz_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // check
    const nyasgz_check = b.addLibrary(.{
        .name = "nyasgz",
        .root_module = nyasgz,
    });
    const exe_check = b.addExecutable(.{
        .name = "nyasgz-exe",
        .root_module = exe.root_module,
    });

    const check = b.step("check", "Check if all compile");
    check.dependOn(&nyasgz_check.step);
    check.dependOn(&exe_check.step);
}

