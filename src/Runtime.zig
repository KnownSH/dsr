const std = @import("std");
const luau = @import("luau");
const luauz = @import("luauz");

const Requirer = @import("core/require/Requirer.zig");
const compile = @import("core/compile.zig");

const Runtime = @This();

allocator: *const std.mem.Allocator,
io: *std.Io,
L: *luau.State,
requirer: *Requirer,

pub fn init(allocator: *const std.mem.Allocator, io: *std.Io) !Runtime {
    var L = try luauz.Luau.init(allocator);
    errdefer L.deinit();

    L.codegen();
    try L.openLibs();

    const requirer = try Requirer.init(io, L.L);
    errdefer requirer.deinit();
    try requirer.install();

    return .{
        .allocator = allocator,
        .io = io,
        .L = L.L,
        .requirer = requirer,
    };
}

pub fn deinit(self: *Runtime) void {
    self.requirer.deinit();
    self.L.deinit();
}

pub fn runFile(self: *Runtime, path: []const u8) !void {
    const allocator = luau.getallocator(self.L);
    const io = self.io.*;
    
    const abs = try std.Io.Dir.path.resolve(allocator, &.{ path });
    defer allocator.free(abs);
    
    const src = try std.Io.Dir.cwd().readFileAlloc(io, abs, allocator, .unlimited);
    defer allocator.free(src);

    const name: [:0]u8 = try allocator.dupeSentinel(u8, abs, 0);
    defer allocator.free(name);

    compile.loadModuleUnsafe(self.L, name, src);

    const status = self.L.pcall(0, 0, 0);
    switch (status) {
        .Ok => {},
        else => {
            const err_msg = self.L.tostring(-1) orelse "UnknownError";
            std.log.err("{s}", .{err_msg});
            std.debug.print("{s}\n", .{self.L.debugtrace()});
            std.process.exit(1);
        }
    }
}