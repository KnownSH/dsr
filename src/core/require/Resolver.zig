const std = @import("std");
const util = @import("../../util/lib.zig");

const Resolver = @This();
const PathType = util.path.PathType;
const AliasMap = std.StringHashMapUnmanaged([]const u8);

pub const ResolveError = error{
    NotRelativeOrAliased,
    UnknownAlias,
    NotFound,
    OutOfMemory,
    AccessDenied,
};

pub const Luaurc = struct {
    aliases: AliasMap = .empty,

    pub fn deinit(self: *Luaurc, allocator: std.mem.Allocator) void {
        freeAliasMap(allocator, &self.aliases);
    }
};

allocator: std.mem.Allocator,
aliases: AliasMap = .empty,

pub fn init(allocator: std.mem.Allocator) !Resolver {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Resolver) void {
    freeAliasMap(self.allocator, &self.aliases);
}

pub fn resolve(self: *Resolver, allocator: std.mem.Allocator, io: std.Io, base_dir: []const u8, req: []const u8) ResolveError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const normalized = try arena_alloc.dupe(u8, req);
    std.mem.replaceScalar(u8, normalized, '\\', '/');

    const joined = switch (PathType.get(normalized)) {
        // ./
        .relative_to_current => try util.path.joinAndCollapse(arena_alloc, base_dir, normalized[2..]),
        // ../
        .relative_to_parent => try util.path.joinAndCollapse(arena_alloc, base_dir, normalized),
        // @alias
        .aliased => try self.resolveAlias(arena_alloc, normalized),
        .unknown => return error.NotRelativeOrAliased,
    };

    const candidates = [_][]const u8{
        joined,
        try std.fmt.allocPrint(arena_alloc, "{s}.luau", .{joined}),
        try std.fmt.allocPrint(arena_alloc, "{s}.lua", .{joined}),
        try std.fmt.allocPrint(arena_alloc, "{s}/init.luau", .{joined}),
        try std.fmt.allocPrint(arena_alloc, "{s}/init.lua", .{joined}),
    };

    const start = @intFromBool(!util.mem.endsWithAny(u8, joined, &.{ ".luau", ".lua" }));

    const cwd = std.Io.Dir.cwd();
    for (candidates[start..]) |candidate| {
        if (!util.path.fileExists(cwd, io, candidate)) continue;
        return std.Io.Dir.path.resolve(allocator, &.{candidate}) catch error.OutOfMemory;
    }
    return error.NotFound;
}

fn resolveAlias(self: *Resolver, allocator: std.mem.Allocator, normalized: []const u8) ![]u8 {
    const split = util.path.splitPath(normalized[1..]);

    var iter = self.aliases.iterator();
    var target: ?[]const u8 = null;
    while (iter.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e.key_ptr.*, split.first)) {
            target = e.value_ptr.*;
            break;
        }
    }

    const t = target orelse return error.UnknownAlias;
    if (split.second.len == 0) return allocator.dupe(u8, t);
    return try util.path.joinAndCollapse(allocator, t, split.second);
}

// util stuff

fn freeAliasMap(allocator: std.mem.Allocator, aliases: *AliasMap) void {
    var iter = aliases.iterator();
    while (iter.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
    aliases.deinit(allocator);
}

test Resolver {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var r = try Resolver.init(allocator, io);
    defer r.deinit();
    
    {
        const got = try r.resolve("test/resolve", "./util");
        try std.testing.expectStringEndsWith(got, "util.luau");
        allocator.free(got);
    }
    {
        const got = try r.resolve("test/resolve/pkg", "../util"); 
        try std.testing.expectStringEndsWith(got, "util.luau");
        allocator.free(got);
    }
    {
        const got = try r.resolve("test/resolve", "./pkg");
        try std.testing.expectStringEndsWith(got, "pkg" ++ std.Io.Dir.path.sep_str ++ "init.luau");
        allocator.free(got);
    }
    {
        try r.aliases.put(allocator, "pkg", "test/resolve/pkg");
        defer _ = r.aliases.remove("pkg");
        const got = try r.resolve("tests/resolve", "@pkg/sub");
        try std.testing.expectStringEndsWith(got, "sub.luau");
        allocator.free(got);
    }
    {
        try std.testing.expectError(error.NotRelativeOrAliased, r.resolve("test/resolve", "util"));
    }
}