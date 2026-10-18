const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the binary") orelse false;
    // Self-hosted backend only on request, for the edit loop; every other
    // build (Debug included) uses LLVM.
    const selfhosted = b.option(bool, "selfhosted", "Use Zig's self-hosted backend (edit loop only)") orelse false;
    const use_llvm: ?bool = if (selfhosted) null else true;

    // Library module exported to consumers (`@import("zig_fping")`).
    const mod = b.addModule("zig_fping", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // CLI front-end.
    const exe = b.addExecutable(.{
        .name = "zfping",
        .use_llvm = use_llvm,
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
    run_cmd.addPassthruArgs();

    // Test-only deterministic fuzz driver (src/testing/fuzz_driver.zig), shared
    // by the library and the CLI test binaries as a named module so the file
    // does not belong to two modules. Only `test` blocks import it.
    const fuzz_driver = b.createModule(.{
        .root_source_file = b.path("src/testing/fuzz_driver.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("fuzz_driver", fuzz_driver);
    exe.root_module.addImport("fuzz_driver", fuzz_driver);

    const mod_tests = b.addTest(.{ .root_module = mod, .use_llvm = use_llvm });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module, .use_llvm = use_llvm });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const driver_tests = b.addTest(.{ .root_module = fuzz_driver, .use_llvm = use_llvm });
    const run_driver_tests = b.addRunArtifact(driver_tests);
    // Always execute the test binaries (only their compilation is cached):
    // a replayed "run test" would hide skip counts and the namespace the
    // tests ran in (scripts/test.sh, scripts/netns-run).
    run_mod_tests.has_side_effects = true;
    run_exe_tests.has_side_effects = true;
    run_driver_tests.has_side_effects = true;

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_driver_tests.step);

    // `zig build fuzz-bins --release=safe --prefix <dir>` installs the two test
    // binaries restricted to the "fuzz driver" tests as <dir>/fuzz/fuzz-lib and
    // <dir>/fuzz/fuzz-cli; scripts/fuzz.sh runs them with ZFPING_FUZZ=<runs>.
    const fuzz_step = b.step("fuzz-bins", "Build the deterministic fuzz-driver test binaries");
    inline for (.{ .{ "fuzz-lib", mod }, .{ "fuzz-cli", exe.root_module } }) |entry| {
        const t = b.addTest(.{
            .name = entry[0],
            .root_module = entry[1],
            .use_llvm = use_llvm,
            .filters = &.{"fuzz driver"},
        });
        const inst = b.addInstallArtifact(t, .{ .dest_dir = .{ .override = .{ .custom = "fuzz" } } });
        fuzz_step.dependOn(&inst.step);
    }
}
