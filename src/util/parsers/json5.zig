const std = @import("std");

pub const JsonObject = std.StringHashMapUnmanaged(JsonValue);

pub const JsonValue = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    big_num: []const u8,
    string: []const u8,
    array: []const JsonValue,
    object: JsonObject,
};

pub const Error = error{
    ReadFailed,
    UnexpectedEnd,
};

pub const Parser = struct {
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,

    line: usize = 1,
    column: usize = 1,
    peeked: ?u8 = null,
    eof: bool = false,

    pub fn init(reader: *std.Io.Reader, allocator: std.mem.Allocator) Parser {
        return .{
            .reader = reader,
            .allocator = allocator,
        };
    }

    fn peekOpt(self: *Parser) Error!?u8 {
        if (self.peeked) |b| return b;
        if (self.eof) return null;

        const byte = self.reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                self.eof = true;
                return null;
            },
            error.ReadFailed => return error.ReadFailed,
        };
        self.peeked = byte;
        return byte;
    }

    fn peek(self: *Parser) Error!u8 {
        return try self.peekOpt() orelse error.UnexpectedEnd;
    }
};