//! A very-opinionated wrapper around zig-luau to make it more like luaz/mlua

const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;

const This = @This();

state: *VM.lua.State,

pub fn init(allocator: *const std.mem.Allocator) !This {
    return .{ .state = try luau.init(allocator) };
}

pub fn codegen(self: *This) bool {
    if (luau.codegen.supported()) {
        luau.codegen.create(self.state);
        return true;
    }
    return false;
}

pub inline fn thread(self: *This) !This {
    return .{ .state = try self.state.newthread() };
}

pub fn sandbox(self: *This) !void {
    if (self.isThread()) {
        try self.state.Lsandboxthread();
    } else {
        try self.state.Lsandbox();
    }
}

pub inline fn isThread(self: *This) bool {
    return self.state != self.state.mainthread();
}

pub inline fn enableCodegen(self: *This) void {
    _ = self.codegen();
}

pub inline fn openLibs(self: *This) !void {
    try self.state.Lopenlibs();
}

pub inline fn deinit(self: *This) void {
    self.state.deinit();
}
