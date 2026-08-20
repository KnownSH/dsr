const std = @import("std");

pub fn endsWithAny(comptime T: type, haystack: []const T, comptime needles: []const []const T) bool {
    inline for (needles) |needle| if (std.mem.endsWith(T, haystack, needle)) return true;
    return false;
}