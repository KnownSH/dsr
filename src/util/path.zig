const std = @import("std");

pub const PathType = enum {
    relative_to_parent,
    relative_to_current,
    aliased,
    unknown,

    pub fn get(path: []const u8) PathType {
        return switch (path[0]) {
            '.' => switch (if (path.len == 1) return .unknown else path[1]) {
                '/', '\\' => return .relative_to_current,
                '.' => switch (if (path.len == 2) return .unknown else path[2]) {
                    '/', '\\' => return .relative_to_parent,
                    else => return .unknown
                }
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
    std.Io.Dir.access(dir, io, path, .{}) catch return false;
    return true;
}

pub fn extractAlias(path: []const u8) []const u8 {
    if (path.len < 1 or path[0] != '@') return "";

    const alias_start = 1;
    const separator_pos = std.mem.findScalar(u8, path, '/') orelse path.len;
    const alias_len = if (separator_pos == path.len)
        path.len - alias_start
    else
        separator_pos - alias_start;

    return path[alias_start .. alias_start + alias_len];
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

    return std.fs.path.join(allocator, &.{ base, normalized });
}
