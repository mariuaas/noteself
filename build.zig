const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("noteself", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const codec = b.createModule(.{
        .root_source_file = b.path("src/codec.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run library tests");
    const check_step = b.step("check", "Compile library tests without running them");

    for ([_][]const u8{ "codec", "midi", "ump", "document" }) |name| {
        const test_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/{s}_test.zig", .{name})),
            .target = target,
            .optimize = optimize,
        });

        if (std.mem.eql(u8, name, "codec")) {
            test_module.addImport("codec", codec);
        } else {
            test_module.addImport("noteself", module);
        }

        const tests = b.addTest(.{
            .name = b.fmt("{s}_test", .{name}),
            .root_module = test_module,
        });
        const run_tests = b.addRunArtifact(tests);

        test_step.dependOn(&run_tests.step);
        check_step.dependOn(&tests.step);
    }
}
