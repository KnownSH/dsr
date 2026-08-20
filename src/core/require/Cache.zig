const std = @import("std");
const luau = @import("luau");

const Cache = @This();

const REGISTRYINDEX = luau.VM.lua.REGISTRYINDEX;

allocator: std.mem.Allocator,
entries: std.StringHashMapUnmanaged(i32) = .empty,
in_progress: std.StringHashMapUnmanaged(void) = .empty,

pub fn init(allocator: std.mem.Allocator) Cache {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Cache, L: *luau.State) void {
    const allocator = self.allocator;
    var iter = self.entries.iterator();
    while (iter.next()) |e| {
        L.unref(e.value_ptr.*);
        allocator.free(e.key_ptr.*);
    }
    self.entries.deinit(allocator);
    
    var ip = self.in_progress.iterator();
    while (ip.next()) |e| allocator.free(e.key_ptr.*);
    self.in_progress.deinit(allocator);
}

pub fn get(self: *Cache, L: *luau.State, canonical: []const u8) bool {
    if (self.entries.get(canonical)) |ref| {
        _ = L.getref(ref);
        return true;
    }
    return false;
}

pub fn isLoading(self: *Cache, canonical: []const u8) bool {
    return self.in_progress.contains(canonical);
}

pub fn beginLoading(self: *Cache, canonical: []const u8) !void {
    const key = try self.allocator.dupe(u8, canonical);
    try self.in_progress.put(self.allocator, key, {});
}

pub fn endLoading(self: *Cache, canonical: []const u8) !void {
    if (self.in_progress.fetchRemove(canonical)) |kv|
        self.allocator.free(kv.key);
}

pub fn store(self: *Cache, L: *luau.State, canonical: []const u8) !void {
    const allocator = luau.getallocator(L);
    const ref = try L.ref(-1) orelse return error.NoRegistry;
    L.pop(1);
    const key = try self.allocator.dupe(u8, canonical);
    try self.entries.put(allocator, key, ref);
}

test "cache stores and retrieves a value by canonical path" {
    var L = try luau.init(&std.testing.allocator);
    defer L.deinit();

    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit(L);

    L.pushinteger(30);
    try cache.store(L, "/abs/init.luau");
    
    try std.testing.expect(!cache.get(L, "/abs/i_dont_exist.luau"));

    try std.testing.expect(cache.get(L, "/abs/init.luau"));
    try std.testing.expectEqual(@as(i64, 30), L.tointeger(-1).?);
    L.pop(1);
}

test "guard flags circular requirers" {
    var L = try luau.init(&std.testing.allocator);
    defer L.deinit();

    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit(L);

    try cache.beginLoading("/abs/a.luau");
    try std.testing.expect(cache.isLoading("/abs/a.luau"));
    try cache.endLoading("/abs/a.luau");
    try std.testing.expect(!cache.isLoading("/abs/a.luau"));
}