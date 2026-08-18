const std = @import("std");
const luau = @import("luau");

const VM = luau.VM;
const LuauState = *VM.lua.State;

const syntax_log = std.log.scoped(.syntax);

const compile_opts = luau.CompileOptions{
    .optimizationLevel = 2,
};

pub fn loadModule(L: LuauState, name: [:0]const u8, content: []const u8) error{Syntax}!void {
    // remove shebang (zune does this so i might as well)
    var script = content;
    if (std.mem.startsWith(u8, content, "#!")) {
        const newline_pos = std.mem.indexOf(u8, content, "\n") orelse content.len;
        script = content[newline_pos..];
    }

    luau.Compiler.Compiler.compileLoad(L, name, script, compile_opts, 0) catch return error.Syntax;

    if (luau.codegen.supported()) {
        luau.codegen.compile(L, -1);
    }
}

/// Causes process to exit if the file cannot be compiled!
pub fn loadModuleUnsafe(L: LuauState, name: [:0]const u8, content: []const u8) void {
    loadModule(L, name, content) catch |err| switch (err) {
        error.Syntax => {
            syntax_log.err("{s}", .{L.tostring(-1) orelse "UnknownError"});
            std.process.exit(1);
        },
    };
}
