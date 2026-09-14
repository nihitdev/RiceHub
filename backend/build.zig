const std = @import("std");
pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{ .name = "ricehub", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    }) });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    b.step("run", "Run the localhost API").dependOn(&run.step);
}
