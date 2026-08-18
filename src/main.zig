const std = @import("std");
const luau = @import("luau");

const DLuau = @import("wrapper/dluau.zig");
const compile = @import("core/compile.zig");
const require = @import("core/require/require.zig");

const Io = std.Io;
const VM = luau.VM;

fn cliRunner(allocator: std.mem.Allocator, io: Io, args: std.process.Args) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const args_slice = try args.toSlice(arena_alloc);

    if (args_slice.len < 2) {
        printHelp();
        std.log.info("You gotta do `puffle.exe run file`", .{});
        return;
    }

    const cmd = args_slice[1];

    if (std.mem.eql(u8, cmd, "run")) {
        try runtime(allocator, io, args_slice[2]);
    } else {
        printHelp();
    }
}

fn printHelp() void {
    const help_infos =
        \\Dergs's Luau Runtime
        \\
        \\USAGE:
        \\    runtime.exe run <file>
        \\
    ;
    std.debug.print("{s}", .{help_infos});
}

/// Ran when `puffle.exe run <file.luau>` is called currently
fn runtime(allocator: std.mem.Allocator, io: Io, file_path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, file_path, allocator, .unlimited) catch |err| {
        std.log.err("cannot read '{s}': {}", .{ file_path, err });
        std.process.exit(1);
    };
    defer allocator.free(content);

    var L = try DLuau.init(&allocator);
    defer L.deinit();

    L.enableCodegen();
    try L.openLibs();

    

    var ML = try L.thread();
    try ML.sandbox();
    ML.state.setsafeenv(VM.lua.GLOBALSINDEX, true);

    const chunk_name = try std.fmt.allocPrintSentinel(allocator, "@{s}", .{file_path}, 0);
    defer allocator.free(chunk_name);

    compile.loadModuleUnsafe(ML.state, chunk_name, content);

    const status = ML.state.pcall(0, 0, 0);
    switch (status) {
        .Ok => {},
        else => {
            const err_msg = ML.state.tostring(-1) orelse "UnknownError";
            std.log.err("{s}", .{err_msg});
            std.debug.print("{s}\n", .{ML.state.debugtrace()});
            std.process.exit(1);
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa; // for now we are just gonna use init
    const io = init.io;
    try cliRunner(allocator, io, init.minimal.args);
}
