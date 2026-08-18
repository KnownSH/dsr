const std = @import("std");
const luau = @import("luau");

const pathutil = @import("../../util/lib.zig").path;

pub const INIT_SUFFIXES: []const [:0]const u8 = &.{
    "/init.luau",
    "/init.lua",
    "\\init.luau",
    "\\init.lua",
};

pub const SUFFIXES: []const [:0]const u8 = &.{
    ".luau",
    ".lua",
};

pub fn removeSuffix(path: []const u8) []const u8 {
    for (INIT_SUFFIXES ++ SUFFIXES) |suffix| {
        if (std.mem.endsWith(u8, path, suffix))
            return path[0..path.len - suffix.len];
    }
    return path;
}

pub fn navigate(
    allocator: std.mem.Allocator,
    cwd: std.Io.Dir,
    from: []const u8,
    path: []const u8,
) ![]u8 {
    const path_type = pathutil.PathType.get(path);
    if (path_type == .unknown) return error.PathUnsupported;

    switch (path_type) {
        .aliased => {
            const alias = try std.ascii.allocLowerString(allocator, try pathutil.extractAlias(path));
            defer allocator.free(alias);

            
        },
        .relative_to_current, .relative_to_parent => {
            
        },
    }
}