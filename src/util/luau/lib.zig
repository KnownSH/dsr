const std = @import("std");
const luau = @import("luau");

pub fn pushGlobalMethod(comptime T: type, L: *luau.State, comptime func: anytype, global_name: [:0]const u8, context: *T) !void {
    const closure = struct {
        fn inner(CL: *luau.State) !i32 {
            const ctx = CL.touserdata(T, luau.VM.lua.upvalueindex(1));
            return func(CL, ctx);
        }
    }.inner;
    
    L.pushlightuserdata(context);
    try L.Zpushclosure(closure, global_name, 1);
    try L.setglobal(global_name);
}