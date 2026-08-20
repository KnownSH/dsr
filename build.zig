const std = @import("std");

fn addDependencies(b: *std.Build, module: *std.Build.Module, args: anytype) void {
    const dep_luau = b.dependency("luau", .{ .target = args.target, .optimize = args.optimize, .Analysis = false });

    module.addImport("luau", dep_luau.module("root"));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const args = .{ .optimize = optimize, .target = target };

    const runtime_root = b.createModule(.{
        .root_source_file = b.path("src/dsr.zig"),
        .target = target,
        .optimize = optimize,
    });

    const submodules = .{
        .utils = b.addModule("utils", .{
            .root_source_file = b.path("src/util/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .luauz = b.addModule("luauz", .{
            .root_source_file = b.path("src/luauz/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    };

    // https://ziggit.dev/t/best-way-to-avoid-import-thing-zig/12080/2
    inline for (@typeInfo(@TypeOf(submodules)).@"struct".fields) |field| {
        const submodule = @field(submodules, field.name);
        runtime_root.addImport(field.name, submodule);
        submodule.addImport("dsr", runtime_root);
        addDependencies(b, submodule, args);
    }
    addDependencies(b, runtime_root, args);
    
    const exe = b.addExecutable(.{
        .name = "puffle",
        .root_module = runtime_root,
    });
    b.installArtifact(exe);

    const unit_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_unit_tests.step);

    const run_step = b.step("run", "Run puffle");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |bargs| {
        run_cmd.addArgs(bargs);
    }
}
