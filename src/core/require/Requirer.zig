const std = @import("std");
const luau = @import("luau");
const util = @import("utils");

const Resolver = @import("Resolver.zig");
const Cache = @import("Cache.zig");
const compile = @import("../compile.zig");

const Requirer = @This();

io: *std.Io,
L: *luau.State,
resolver: Resolver,
cache: Cache,

pub fn init(io: *std.Io, L: *luau.State) !*Requirer {
    const allocator = luau.getallocator(L);
    const self = try allocator.create(Requirer);
    errdefer allocator.destroy(self);

    self.* = .{
        .io = io,
        .L = L,
        .resolver = try .init(allocator),
        .cache = .init(allocator),
    };
    return self;
}

pub fn deinit(self: *Requirer) void {
    self.cache.deinit(self.L);
    self.resolver.deinit();

    const a = luau.getallocator(self.L);
    a.destroy(self);
}

pub fn install(self: *Requirer) !void {
    const L = self.L;
    L.pushlightuserdata(self);
    try util.luau.pushGlobalMethod(Requirer, L, requireImpl, "require", self);
}

fn loadModule(self: *Requirer, canonical: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(luau.getallocator(self.L));
    defer arena.deinit();
    const allocator = arena.allocator();
    
    const GL = self.L.mainthread();
    const ML = try GL.newthread();
    GL.xmove(self.L, 1);
    try ML.Lsandboxthread();
    
    const src = try std.Io.Dir.cwd().readFileAlloc(self.io.*, canonical, allocator, .unlimited);
    const name: [:0]u8 = try allocator.dupeSentinel(u8, canonical, 0);

    try compile.loadModule(ML, name, src);
    _ = try ML.pcall(0, 1, 0).check();
    
    ML.xmove(self.L, 1);
}

fn requireImpl(L: *luau.State, maybe_self: ?*Requirer) !i32 {
    const allocator = luau.getallocator(L);
    const self = maybe_self orelse return L.Zerror("Runtime not loaded");
    const req = try L.Zcheckvalue([:0]const u8, 1, "");

    var ar: luau.VM.lua.Debug = .{ .ssbuf = undefined };
    {
        var level: i32 = 1;
        while (true) : (level += 1) {
            if (!L.getinfo(level, "s", &ar))
                return L.Zerror("require is not supported in this context");
            if (ar.what == .lua) break;
        }
    }

    const ctx = ar.source orelse return L.Zerror("bad context");
    const base_dir = util.path.dirname(ctx) orelse ".";
    const resolved = self.resolver.resolve(allocator, self.io.*, base_dir, req) catch |err| return switch (err) {
        error.UnknownAlias => L.Zerrorf("require: unknown alias in \"{s}\"", .{req}),
        error.NotFound => L.Zerrorf("require: module \"{s}\" not found", .{req}),
        error.NotRelativeOrAliased => L.Zerrorf("require: \"{s}\" is not a relative path or alias", .{req}),
        else => L.Zerrorf("require: resolution failed for \"{s}\"", .{req}),
    };
    defer allocator.free(resolved);

    if (self.cache.get(L, resolved)) return 1;
    if (self.cache.isLoading(resolved)) {
        return L.Zerrorf("require: circular dependency detected for \"{s}\"", .{resolved});
    }

    try self.cache.beginLoading(resolved);
    defer self.cache.endLoading(resolved) catch {};

    self.loadModule(resolved) catch {
        return L.Zerrorf("require: failed to load \"{s}\"", .{resolved});
    };

    self.cache.store(L, resolved) catch {
        return L.Zerrorf("require: out of memory caching \"{s}\"", .{resolved});
    };
    
    _ = self.cache.get(L, resolved);
    return 1;
}

test {
    _ = Resolver;
    _ = Cache;
}