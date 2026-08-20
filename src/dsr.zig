const std = @import("std");
const Runtime = @import("Runtime.zig");

fn cliRunner(init: std.process.Init, args: std.process.Args) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
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
        const gpa = init.gpa;
        var io = init.io;
        var rt = try Runtime.init(&gpa, &io);
        defer rt.deinit();
        try rt.runFile(args_slice[2]);
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

pub fn main(init: std.process.Init) !void {
    try cliRunner(init, init.minimal.args);
}

test {
    _ = @import("core/require/Requirer.zig");
    _ = @import("utils");
}