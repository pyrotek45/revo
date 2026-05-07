const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ReplBackend = enum { libedit, readline, bestline, none };
    const repl_backend = b.option(ReplBackend, "repl", "which repl backend to use") orelse .bestline;

    const build_options = b.addOptions();
    build_options.addOption(ReplBackend, "repl_backend", repl_backend);
    build_options.addOption([]const u8, "version", "0.0.1a");

    const vm_mod = b.addModule("vm", .{
        .root_source_file = b.path("src/vm/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const revo_mod = b.addModule("revo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const all_mods = [_]*std.Build.Module{ vm_mod, revo_mod };
    const imports = [_]struct { []const u8, *std.Build.Module }{
        .{ "revo", revo_mod },
        .{ "vm", vm_mod },
    };
    for (all_mods) |mod|
        for (imports) |imp|
            mod.addImport(imp[0], imp[1]);

    const test_filters = b.option(
        []const []const u8,
        "test_filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const is_freestanding = target.result.os.tag == .freestanding;
    const exe_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // even without the if stmt it costs nothing when compiled in when a different backend is avaliable
    // i genuinely dont know why
    if (!is_freestanding) {
        if (repl_backend == .bestline) {
            exe_root.addCSourceFile(.{
                .file = b.path("vendor/bestline.c"),
                .flags = &.{},
            });
            exe_root.addIncludePath(b.path("vendor"));
        }

        // get via @import("build_options").
        exe_root.addOptions("build_options", build_options);

        switch (repl_backend) {
            .libedit => exe_root.linkSystemLibrary("edit", .{ .preferred_link_mode = .dynamic }),
            .readline => exe_root.linkSystemLibrary("readline", .{ .preferred_link_mode = .dynamic }),
            .bestline => {},
            .none => {},
        }
    }

    for (imports) |imp| exe_root.addImport(imp[0], imp[1]);

    const tests_root = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    for (imports) |imp| tests_root.addImport(imp[0], imp[1]);

    const exe = b.addExecutable(.{ .name = "revo", .root_module = exe_root });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "run the cli").dependOn(&run_cmd.step);

    const check_modules = [_]*std.Build.Module{
        tests_root, revo_mod, vm_mod, exe_root,
    };

    const test_step = b.step("test", "run all tests");
    for (check_modules) |mod| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{
            .root_module = mod,
            .filters = test_filters,
        })).step);
    }

    const check_step = b.step("check", "compile the project without running it");
    check_step.dependOn(&b.addExecutable(.{ .name = "revo-check", .root_module = exe_root }).step);
    for (check_modules) |mod| {
        check_step.dependOn(&b.addTest(.{ .root_module = mod, .filters = test_filters }).step);
    }
}
