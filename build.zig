const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the binary") orelse false;

    // Library module exported to consumers (`@import("zig_fping")`).
    const mod = b.addModule("zig_fping", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // CLI front-end.
    const exe = b.addExecutable(.{
        .name = "zfping",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "zig_fping", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Man page, installed like fping's `man_MANS` (mandir/man8) so a
    // `zig build --prefix /usr/local` lands it where `man zfping` finds it.
    b.installFile("doc/zfping.8", "share/man/man8/zfping.8");

    const run_step = b.step("run", "Run zfping");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
