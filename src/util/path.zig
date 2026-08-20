const std = @import("std");

pub const INIT_SUFFIXES: []const [:0]const u8 = &.{
    "/init.luau",
    "/init.lua",
};

pub const SUFFIXES: []const [:0]const u8 = &.{
    ".luau",
    ".lua",
};

pub const PathType = enum {
    relative_to_parent,
    relative_to_current,
    aliased,
    unknown,

    pub fn get(path: []const u8) PathType {
        if (path.len == 0) return .unknown;
        return switch (path[0]) {
            '.' => switch (if (path.len == 1) return .unknown else path[1]) {
                '/', '\\' => return .relative_to_current,
                '.' => switch (if (path.len == 2) return .unknown else path[2]) {
                    '/', '\\' => return .relative_to_parent,
                    else => return .unknown,
                },
                else => return .unknown,
            },
            '@' => .aliased,
            else => .unknown,
        };
    }
};

pub const Split = struct {
    first: []const u8,
    second: []const u8,
};

pub fn splitPath(path: []const u8) Split {
    const pos = std.mem.findScalar(u8, path, '/') orelse path.len;
    return .{
        .first = path[0..pos],
        .second = if (pos < path.len) path[pos + 1 ..] else "",
    };
}

pub fn fileExists(dir: std.Io.Dir, io: std.Io, path: []const u8) bool {
    std.Io.Dir.access(dir, io, path, .{ .read = true }) catch return false;
    return true;
}

/// Returns only the directory part of the path + prefixed slash if there is one.
/// If there isn't a directory, then returns null.
pub fn dirname(path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;

    const root_slice = std.fs.path.parsePath(path);
    if (path.len == root_slice.root.len) return null;
    
    var end_index = path.len - 1;
    while (path[end_index] == '/' or path[end_index] == '\\') {
        if (end_index == 0) return null;
        end_index -= 1;
    }

    while (path[end_index] != '/' and path[end_index] != '\\') {
        if (end_index == 0) return null;
        end_index -= 1;
    }

    if (end_index == 0) return null;
    return path[0..end_index];
}

/// Joins two paths, normalizes backslashes into forward slashes as well.
pub fn joinPath(allocator: std.mem.Allocator, base: []const u8, rest: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, rest);
    defer allocator.free(normalized);
    std.mem.replaceScalar(u8, normalized, '\\', '/');

    return std.Io.Dir.path.resolve(allocator, &.{ base, normalized });
}

pub fn joinAndCollapse(allocator: std.mem.Allocator, base: []const u8, rest: []const u8) ![]u8 {
    return std.Io.Dir.path.resolve(allocator, &.{ base, rest });
}