const std = @import("std");

// A consumer's build.zig: zig-fping is a package dependency and its library
// module is taken from it by name.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // ReleaseSafe by default: every safety check stays on, which is what a
    // network-facing daemon wants.
    const optimize = b.option(std.lang.Optimize, "optimize", "Optimization mode (default: safe)") orelse .safe;
    // LLVM unless -Dselfhosted: the self-hosted backend is for the edit loop only.
    const selfhosted = b.option(bool, "selfhosted", "Use Zig's self-hosted backend (edit loop only)") orelse false;
    const use_llvm: ?bool = if (selfhosted) null else true;
    const strip = b.option(bool, "strip", "Strip debug info (bundle.sh does)");

    const version = @import("build.zig.zon").version;
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const fping = b.dependency("zig_fping", .{ .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zig_fping", .module = fping.module("zig_fping") },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });

    const exe = b.addExecutable(.{ .name = "fping-watch", .root_module = mod, .use_llvm = use_llvm });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run (pass options after --, e.g. -- --listen 127.0.0.1:8080)").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod, .use_llvm = use_llvm });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The about page for a demo hub, from deploy/about.json, into
    // zig-out/about/ (package.sh ships it in the .deb). A host tool, not
    // part of the daemon.
    const about_mod = b.createModule(.{
        .root_source_file = b.path("tools/about.zig"),
        .target = b.graph.host,
        .optimize = .safe,
    });
    const about_tool = b.addExecutable(.{ .name = "about", .root_module = about_mod, .use_llvm = use_llvm });
    const gen = b.addRunArtifact(about_tool);
    gen.addFileArg(b.path("deploy/about.json"));
    gen.addArg(version);
    const about_step = b.step("about", "Generate the about page into zig-out/about/");
    inline for (.{ "about.json", "about.html", "about-card.html" }) |name|
        about_step.dependOn(&b.addInstallFile(gen.addOutputFileArg(name), "about/" ++ name).step);
    about_step.dependOn(&b.addInstallFile(b.path("doc/screenshot.png"), "about/screenshot.png").step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = about_mod, .use_llvm = use_llvm })).step);
}
