const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    // Release packages leave the debug information out (tools/package-linux.sh).
    const strip = b.option(bool, "strip", "Leave debug information out of nanoterm");
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    const exe = b.addExecutable(.{ .name = "nanoterm", .root_module = mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run nanoterm").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    b.step("test", "Run nanoterm's tests").dependOn(&b.addRunArtifact(tests).step);
    // The tests as a program, for another machine (Linux in a container).
    b.step("test-bin", "Install the tests as zig-out/bin/nanoterm-tests").dependOn(&b.addInstallArtifact(tests, .{ .dest_sub_path = "nanoterm-tests" }).step);

    // The terminal benchmark (bench/README.md): its workloads and report, and
    // nanoterm's engine as a runner. Build it with -Doptimize=ReleaseFast.
    const vt_mod = b.createModule(.{
        .root_source_file = b.path("src/vt.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    const runner = b.addExecutable(.{ .name = "nanoterm-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/nanoterm_bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vt", .module = vt_mod }},
    }) });
    const termbench = b.addExecutable(.{ .name = "termbench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/termbench.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    // A video of nanoterm, rendered offscreen (src/video.zig).
    const video = b.addExecutable(.{ .name = "nanoterm-video", .root_module = b.createModule(.{
        .root_source_file = b.path("src/video.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    }) });
    b.step("video", "Build zig-out/bin/nanoterm-video").dependOn(&b.addInstallArtifact(video, .{}).step);

    const bench = b.step("bench", "Build the terminal benchmark (bench/README.md)");
    bench.dependOn(&b.addInstallArtifact(runner, .{}).step);
    bench.dependOn(&b.addInstallArtifact(termbench, .{}).step);
}
