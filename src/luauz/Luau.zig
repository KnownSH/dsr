const std = @import("std");
const builtin = @import("builtin");
const luau = @import("luau");

const Luau = @This();

pub const VM = luau.VM;

const DEFAULT_ALLOCATOR = if (builtin.link_libc)
    std.heap.c_allocator
else if (!builtin.single_threaded)
    std.heap.smp_allocator
else
    std.heap.page_allocator;

L: *luau.State,

/// Creates a new luau state and loads **all** standard libraries.
pub fn init(allocator: ?*const std.mem.Allocator) !Luau {
    const alloc = allocator orelse &DEFAULT_ALLOCATOR;
    const L = try luau.init(alloc);
    
    return .{
        .L = L,
    };
}

pub fn deinit(self: *Luau) void {
    self.L.deinit();
}

/// Enable native code generation for this luau state if possible.
pub fn codegen(self: *Luau) void {
    if (luau.codegen.supported()) {
        luau.codegen.create(self.L);
    }
}

/// Open all standard libraries.
pub inline fn openLibs(self: *Luau) !void {
    try self.L.Lopenlibs();
}

pub inline fn getAllocator(self: *Luau) std.mem.Allocator {
    return luau.getallocator(self.L);
}