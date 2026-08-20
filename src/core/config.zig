const std = @import("std");
const util = @import("utils");
const navigator = @import("require/navigator.zig");

const Io = std.Io;

pub fn getLuauConfig(allocator: std.mem.Allocator, io: Io, from: []const u8) void {
    _ = allocator; _ = io; _ = from;
    
}

/// from is the starting path, dir is the current working directory (usually)
fn walkDir(allocator: std.mem.Allocator, dir: Io.Dir, from: []const u8) !void {
    var current_dir = navigator.removeSuffix(from);

    _ = allocator; _ = dir;

    while (util.path.dirname(current_dir)) |parent_dir| : (current_dir = parent_dir) {
        
    }
}

fn parseLuaurc(allocator: std.mem.Allocator, binary: []const u8) void {
    _ = allocator; _ = binary;
}

test "config" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    {
        getLuauConfig(allocator, io, "");
    }
}