const std = @import("std");

fn addDependencies(b: *std.Build, module: *std.Build.Module, args: anytype) void {
    const dep_luau = b.dependency("luau", .{ .target = args.target, .optimize = args.optimize, .Analysis = false });

    module.addImport("luau", dep_luau.module("root"));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const args = .{ .optimize = optimize, .target = target };
    
    const exe = b.addExecutable(.{
        .name = "puffle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addDependencies(b, exe.root_module, args);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run puffle");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |bargs| {
        run_cmd.addArgs(bargs);
    }
}
