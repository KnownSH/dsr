//! This is directly derived from `std.json`, with extensions to make it work with json5.

const std = @import("std");

const json = std.json;

pub const Token = json.Token;
pub const TokenType = json.TokenType;
pub const AllocWhen = json.AllocWhen;
pub const Diagnostics = json.Diagnostics;
pub const Error = json.Error;
pub const default_max_value_len = json.default_max_value_len;
pub const default_buffer_size = json.default_buffer_size;

const Allocator = std.mem.Allocator;
const BitStack = std.BitStack;
const assert = std.debug.assert;

const OBJECT_MODE = 0;
const ARRAY_MODE = 1;

const State = enum {
    value,
    post_value,
    object_start,
    object_post_comma,
    array_start,
    array_post_comma,
    identifier_key,

    number_sign,
    number_leading_zero,
    number_hex_digit_1,
    number_hex,
    number_int,
    number_dot,
    number_post_dot,
    number_frac,
    number_post_e,
    number_post_e_sign,
    number_exp,

    string,
    string_backslash,
    string_backslash_x_1,
    string_backslash_x_2,
    string_backslash_u,
    string_backslash_u_1,
    string_backslash_u_2,
    string_backslash_u_3,
    string_surrogate_half,
    string_surrogate_half_backslash,
    string_surrogate_half_backslash_u,
    string_surrogate_half_backslash_u_1,
    string_surrogate_half_backslash_u_2,
    string_surrogate_half_backslash_u_3,

    string_utf8_last_byte,
    string_utf8_second_to_last_byte,
    string_utf8_second_to_last_byte_guard_against_overlong,
    string_utf8_second_to_last_byte_guard_against_surrogate_half,
    string_utf8_third_to_last_byte,
    string_utf8_third_to_last_byte_guard_against_overlong,
    string_utf8_third_to_last_byte_guard_against_too_large,

    literal_t,
    literal_f,
    literal_n,
    literal_inf_n,
    literal_nan_a,
};

pub const Scanner = struct {
    state: State = .value,
    string_is_object_key: bool = false,
    quote_char: u8 = '"',
    hex_byte: u8 = 0,
    stack: BitStack,
    value_start: usize = undefined,
    utf16_code_units: [2]u16 = undefined,

    input: []const u8 = "",
    cursor: usize = 0,
    is_end_of_input: bool = false,
    diagnostics: ?*Diagnostics = null,

    pub const NextError = json.Scanner.NextError;
    pub const AllocError = json.Scanner.AllocError;
    pub const PeekError = json.Scanner.PeekError;
    pub const SkipError = json.Scanner.SkipError;
    pub const AllocIntoArrayListError = json.Scanner.AllocIntoArrayListError;

    pub fn initStreaming(allocator: Allocator) Scanner {
        return .{
            .stack = .init(allocator),
        };
    }

    pub fn initCompleteInput(allocator: Allocator, complete_input: []const u8) Scanner {
        return .{
            .stack = .init(allocator),
            .input = complete_input,
            .is_end_of_input = true,
        };
    }

    pub fn deinit(self: *Scanner) void {
        self.stack.deinit();
        self.* = undefined;
    }

    pub fn enableDiagnostics(self: *Scanner, input: []const u8) void {
        assert(self.cursor == self.input.len);
        if (self.diagnostics) |diag| {
            diag.total_bytes_before_current_input += self.input.len;
            diag.line_start_cursor -%= self.cursor;
        }
        self.input = input;
        self.cursor = 0;
        self.value_start = 0;
    }

    pub fn endInput(self: *Scanner) void {
        self.is_end_of_input = true;
    }

    pub fn stackHeight(self: *const Scanner) usize {
        return self.stack.bit_len;
    }

    pub fn ensureTotalStackCapacity(self: *Scanner, height: usize) Allocator.Error!void {
        try self.stack.ensureTotalCapacity(height);
    }

    pub fn nextAlloc(self: *Scanner, allocator: Allocator, when: AllocWhen) AllocError!Token {
        return self.nextAllocMax(allocator, when, default_max_value_len);
    }

    pub fn nextAllocMax(self: *Scanner, allocator: Allocator, when: AllocWhen, max_value_len: usize) AllocError!Token {
        assert(self.is_end_of_input);

        const token_type = self.peekNextTokenType() catch |e| switch (e) {
            error.BufferUnderrun => unreachable,
            else => |err| return err,
        };

        switch (token_type) {
            .number, .string => {
                var value_list: std.ArrayList(u8) = .empty;
                errdefer value_list.deinit(allocator);

                if (self.allocNextIntoArrayListMax(allocator, &value_list, when, max_value_len) catch |e| switch (e) {
                    error.BufferUnderrun => unreachable,
                    else => |err| return err,
                }) |slice| {
                    return if (token_type == .number)
                        Token{ .number = slice }
                    else
                        Token{ .string = slice };
                } else {
                    return if (token_type == .number)
                        Token{ .allocated_number = try value_list.toOwnedSlice(allocator) }
                    else
                        Token{ .allocated_string = try value_list.toOwnedSlice(allocator) };
                }
            },
            .object_begin, .object_end, .array_begin, .array_end, .true, .false, .null, .end_of_document => {
                return self.next() catch |e| switch (e) {
                    error.BufferUnderrun => unreachable,
                    else => |err| return err,
                };
            },
        }
    }

    pub fn allocNextIntoArrayList(self: *Scanner, allocator: Allocator, value_list: *std.ArrayList(u8), when: AllocWhen) AllocIntoArrayListError!?[]const u8 {
        return self.allocNextIntoArrayListMax(allocator, value_list, when, default_max_value_len);
    }

    pub fn allocNextIntoArrayListMax(self: *Scanner, allocator: Allocator, value_list: *std.ArrayList(u8), when: AllocWhen, max_value_len: usize) AllocIntoArrayListError!?[]const u8 {
        while (true) {
            const token = try self.next();
            switch (token) {
                .partial_number, .partial_string => |slice| try appendSlice(allocator, value_list, slice, max_value_len),

                .partial_string_escaped_1 => |buf| try appendSlice(allocator, value_list, &buf, max_value_len),
                .partial_string_escaped_2 => |buf| try appendSlice(allocator, value_list, &buf, max_value_len),
                .partial_string_escaped_3 => |buf| try appendSlice(allocator, value_list, &buf, max_value_len),
                .partial_string_escaped_4 => |buf| try appendSlice(allocator, value_list, &buf, max_value_len),

                .number, .string => |slice| {
                    if (when == .alloc_if_needed and value_list.items.len == 0) return slice;
                    try appendSlice(allocator, value_list, slice, max_value_len);
                    return null;
                },

                .object_begin, .object_end, .array_begin, .array_end, .true, .false, .null, .end_of_document, .allocated_number, .allocated_string => unreachable,
            }
        }
    }

    pub fn skipValue(self: *Scanner) SkipError!void {
        assert(self.is_end_of_input);
        switch (self.peekNextTokenType() catch |e| switch (e) {
            error.BufferUnderrun => unreachable,
            else => |err| return err,
        }) {
            .object_begin, .array_begin => {
                self.skipUntilStackHeight(self.stackHeight()) catch |e| switch (e) {
                    error.BufferUnderrun => unreachable,
                    else => |err| return err,
                };
            },
            .number, .string => {
                while (true) {
                    switch (self.next() catch |e| switch (e) {
                        error.BufferUnderrun => unreachable,
                        else => |err| return err,
                    }) {
                        .partial_number, .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => continue,
                        .number, .string => break,
                        else => unreachable,
                    }
                }
            },
            .true, .false, .null => {
                _ = self.next() catch |e| switch (e) {
                    error.BufferUnderrun => unreachable,
                    else => |err| return err,
                };
            },
            .object_end, .array_end, .end_of_document => unreachable,
        }
    }

    pub fn skipUntilStackHeight(self: *Scanner, terminal_stack_height: usize) NextError!void {
        while (true) {
            switch (try self.next()) {
                .object_end, .array_end => {
                    if (self.stackHeight() == terminal_stack_height) break;
                },
                .end_of_document => unreachable,
                else => continue,
            }
        }
    }

    pub fn next(self: *Scanner) NextError!Token {
        state_loop: while (true) {
            switch (self.state) {
                .value => {
                    const b = try self.skipWhitespaceAndCommentsExpectByte();

                    switch (b) {
                        '{' => {
                            try self.stack.push(OBJECT_MODE);
                            self.cursor += 1;
                            self.state = .object_start;
                            return .object_begin;
                        },

                        '[' => {
                            try self.stack.push(ARRAY_MODE);
                            self.cursor += 1;
                            self.state = .array_start;
                            return .array_begin;
                        },

                        '"', '\'' => {
                            self.quote_char = b;
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .string;
                            continue :state_loop;
                        },

                        '+', '-' => {
                            self.value_start = self.cursor;
                            self.cursor += 1;
                            self.state = .number_sign;
                            continue :state_loop;
                        },

                        '0' => {
                            self.value_start = self.cursor;
                            self.cursor += 1;
                            self.state = .number_leading_zero;
                            continue :state_loop;
                        },

                        '1'...'9' => {
                            self.value_start = self.cursor;
                            self.cursor += 1;
                            self.state = .number_int;
                            continue :state_loop;
                        },

                        '.' => {
                            self.value_start = self.cursor;
                            self.cursor += 1;
                            self.state = .number_dot;
                            continue :state_loop;
                        },

                        'I' => {
                            self.value_start = self.cursor;
                            self.cursor += 1;
                            self.state = .literal_inf_n;
                            continue :state_loop;
                        },

                        'N' => {
                            self.value_start = self.cursor;
                            self.cursor += 1;
                            self.state = .literal_nan_a;
                            continue :state_loop;
                        },

                        't' => {
                            self.cursor += 1;
                            self.state = .literal_t;
                            continue :state_loop;
                        },

                        'f' => {
                            self.cursor += 1;
                            self.state = .literal_f;
                            continue :state_loop;
                        },

                        'n' => {
                            self.cursor += 1;
                            self.state = .literal_n;
                            continue :state_loop;
                        },

                        else => return error.SyntaxError,
                    }
                },

                .post_value => {
                    if (try self.skipWhitespaceAndCommentsCheckEnd()) return .end_of_document;

                    const c = self.input[self.cursor];
                    if (self.string_is_object_key) {
                        self.string_is_object_key = false;
                        switch (c) {
                            ':' => {
                                self.cursor += 1;
                                self.state = .value;
                                continue :state_loop;
                            },
                            else => return error.SyntaxError,
                        }
                    }

                    switch (c) {
                        '}' => {
                            if (self.stack.pop() != OBJECT_MODE) return error.SyntaxError;
                            self.cursor += 1;
                            return .object_end;
                        },

                        ']' => {
                            if (self.stack.pop() != ARRAY_MODE) return error.SyntaxError;
                            self.cursor += 1;
                            return .array_end;
                        },

                        ',' => {
                            self.state = switch (self.stack.peek()) {
                                OBJECT_MODE => .object_post_comma,
                                ARRAY_MODE => .array_post_comma,
                            };
                            self.cursor += 1;
                            continue :state_loop;
                        },

                        else => return error.SyntaxError,
                    }
                },

                .object_start, .object_post_comma => {
                    const c = try self.skipWhitespaceAndCommentsExpectByte();
                    switch (c) {
                        '"', '\'' => {
                            self.quote_char = c;
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .string;
                            self.string_is_object_key = true;
                            continue :state_loop;
                        },

                        'a'...'z', 'A'...'Z', '_', '$' => {
                            self.value_start = self.cursor;
                            self.cursor += 1;
                            self.state = .identifier_key;
                            self.string_is_object_key = true;
                            continue :state_loop;
                        },

                        '}' => {
                            self.cursor += 1;
                            _ = self.stack.pop();
                            self.state = .post_value;
                            return .object_end;
                        },

                        else => return error.SyntaxError,
                    }
                },

                .array_start, .array_post_comma => {
                    const c = try self.skipWhitespaceAndCommentsExpectByte();
                    switch (c) {
                        ']' => {
                            self.cursor += 1;
                            _ = self.stack.pop();
                            self.state = .post_value;
                            return .array_end;
                        },

                        else => {
                            self.state = .value;
                            continue :state_loop;
                        },
                    }
                },

                .identifier_key => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            'a'...'z', 'A'...'Z', '0'...'9', '_', '$' => continue,
                            else => {
                                self.state = .post_value;
                                return Token{ .string = self.takeValueSlice() };
                            },
                        }
                    }

                    if (self.is_end_of_input) {
                        self.state = .post_value;
                        return Token{ .string = self.takeValueSlice() };
                    }

                    const slice = self.takeValueSlice();
                    if (slice.len > 0) return Token{ .partial_string = slice };
                    return error.BufferUnderrun;
                },

                .number_sign => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInNumber(false);
                    switch (self.input[self.cursor]) {
                        '0' => {
                            self.cursor += 1;
                            self.state = .number_leading_zero;
                        },

                        '1'...'9' => {
                            self.cursor += 1;
                            self.state = .number_int;
                        },

                        '.' => {
                            self.cursor += 1;
                            self.state = .number_dot;
                        },

                        'I' => {
                            self.cursor += 1;
                            self.state = .literal_inf_n;
                        },

                        'N' => {
                            self.cursor += 1;
                            self.state = .literal_nan_a;
                            continue :state_loop;
                        },

                        else => return error.SyntaxError,
                    }
                    continue :state_loop;
                },

                .number_leading_zero => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInNumber(true);
                    switch (self.input[self.cursor]) {
                        'x', 'X' => {
                            self.cursor += 1;
                            self.state = .number_hex_digit_1;
                            continue :state_loop;
                        },

                        '.' => {
                            self.cursor += 1;
                            self.state = .number_post_dot;
                            continue :state_loop;
                        },

                        'e', 'E' => {
                            self.cursor += 1;
                            self.state = .number_dot;
                            continue :state_loop;
                        },

                        else => {
                            self.state = .post_value;
                            return Token{ .number = self.takeValueSlice() };
                        },
                    }
                },

                .number_hex_digit_1 => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInNumber(false);
                    switch (self.input[self.cursor]) {
                        '0'...'9', 'a'...'f', 'A'...'F' => {
                            self.cursor += 1;
                            self.state = .number_hex;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .number_hex => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            '0'...'9', 'a'...'f', 'A'...'F' => continue,
                            else => {
                                self.state = .post_value;
                                return Token{ .number = self.takeValueSlice() };
                            },
                        }
                    }
                    return self.endOfBufferInNumber(true);
                },

                .number_int => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            '0'...'9' => continue,

                            '.' => {
                                self.cursor += 1;
                                self.state = .number_post_dot;
                                continue :state_loop;
                            },

                            'e', 'E' => {
                                self.cursor += 1;
                                self.state = .number_post_e;
                                continue :state_loop;
                            },

                            else => {
                                self.state = .post_value;
                                return Token{ .number = self.takeValueSlice() };
                            },
                        }
                    }
                    return self.endOfBufferInNumber(true);
                },

                .number_dot => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInNumber(false);
                    switch (self.input[self.cursor]) {
                        '0'...'9' => {
                            self.cursor += 1;
                            self.state = .number_frac;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .number_post_dot => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInNumber(true);
                    switch (self.input[self.cursor]) {
                        '0'...'9' => {
                            self.cursor += 1;
                            self.state = .number_frac;
                            continue :state_loop;
                        },

                        'e', 'E' => {
                            self.cursor += 1;
                            self.state = .number_post_e;
                            continue :state_loop;
                        },

                        else => {
                            self.state = .post_value;
                            return Token{ .number = self.takeValueSlice() };
                        },
                    }
                },

                .number_frac => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            '0'...'9' => continue,

                            'e', 'E' => {
                                self.cursor += 1;
                                self.state = .number_post_e;
                                continue :state_loop;
                            },

                            else => {
                                self.state = .post_value;
                                return Token{ .number = self.takeValueSlice() };
                            },
                        }
                    }
                    return self.endOfBufferInNumber(true);
                },

                .number_post_e => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInNumber(false);
                    switch (self.input[self.cursor]) {
                        '0'...'9' => {
                            self.cursor += 1;
                            self.state = .number_post_e_sign;
                            continue :state_loop;
                        },

                        '+', '-' => {
                            self.cursor += 1;
                            self.state = .number_post_e_sign;
                            continue :state_loop;
                        },

                        else => return error.SyntaxError,
                    }
                },

                .number_post_e_sign => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInNumber(false);
                    switch (self.input[self.cursor]) {
                        '0'...'9' => {
                            self.cursor += 1;
                            self.state = .number_exp;
                            continue :state_loop;
                        },

                        else => return error.SyntaxError,
                    }
                },

                .number_exp => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        switch (self.input[self.cursor]) {
                            '0'...'9' => continue,
                            else => {
                                self.state = .post_value;
                                return Token{ .number = self.takeValueSlice() };
                            },
                        }
                    }
                    return self.endOfBufferInNumber(true);
                },

                .string => {
                    while (self.cursor < self.input.len) : (self.cursor += 1) {
                        const c = self.input[self.cursor];
                        if (c == self.quote_char) {
                            const result = Token{ .string = self.takeValueSlice() };
                            self.cursor += 1;
                            self.state = .post_value;
                            return result;
                        }

                        switch (c) {
                            0x00...0x1f => {
                                if (c == '\n' or c == '\r') return error.SyntaxError;
                                continue;
                            },

                            '\\' => {
                                const slice = self.takeValueSlice();
                                self.cursor += 1;
                                self.state = .string_backslash;
                                if (slice.len > 0) return Token{ .partial_string = slice };
                                continue :state_loop;
                            },

                            0xC2...0xDF => {
                                self.cursor += 1;
                                self.state = .string_utf8_last_byte;
                                continue :state_loop;
                            },

                            0xE0 => {
                                self.cursor += 1;
                                self.state = .string_utf8_third_to_last_byte_guard_against_overlong;
                                continue :state_loop;
                            },

                            0xE1...0xEC, 0xEE...0xEF => {
                                self.cursor += 1;
                                self.state = .string_utf8_second_to_last_byte;
                                continue :state_loop;
                            },

                            0xED => {
                                self.cursor += 1;
                                self.state = .string_utf8_second_to_last_byte_guard_against_surrogate_half;
                                continue :state_loop;
                            },

                            0xF0 => {
                                self.cursor += 1;
                                self.state = .string_utf8_third_to_last_byte_guard_against_overlong;
                                continue :state_loop;
                            },

                            0xF1...0xF3 => {
                                self.cursor += 1;
                                self.state = .string_utf8_third_to_last_byte;
                                continue :state_loop;
                            },

                            0xF4 => {
                                self.cursor += 1;
                                self.state = .string_utf8_third_to_last_byte_guard_against_too_large;
                                continue :state_loop;
                            },

                            0x80...0xC1, 0xF5...0xFF => return error.SyntaxError,
                            else => continue,
                        }
                    }
                    if (self.is_end_of_input) return error.UnexpectedEndOfInput;
                    const slice = self.takeValueSlice();
                    if (slice.len > 0) return Token{ .partial_string = slice };
                    return error.BufferUnderrun;
                },

                .string_backslash => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();

                    const c = self.input[self.cursor];
                    switch (c) {
                        'b', 'f', 'n', 'r', 't', 'v', '0' => |esc| {
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .string;
                            return Token{ .partial_string_escaped_1 = switch (esc) {
                                'b' => [_]u8{0x08},
                                'f' => [_]u8{0x0C},
                                'n' => [_]u8{'\n'},
                                'r' => [_]u8{'\r'},
                                't' => [_]u8{'\t'},
                                'v' => [_]u8{0x0B},
                                '0' => [_]u8{0x00},
                                else => [_]u8{0x00},
                            } };
                        },

                        'x' => {
                            self.cursor += 1;
                            self.state = .string_backslash_x_1;
                            continue :state_loop;
                        },

                        'u' => {
                            self.cursor += 1;
                            self.state = .string_backslash_u;
                            continue :state_loop;
                        },

                        '\n' => {
                            if (self.diagnostics) |diag| {
                                diag.line_number += 1;
                                diag.line_start_cursor = self.cursor;
                            }
                            self.cursor += 1;
                            self.value_start = self.cursor;
                            self.state = .string;
                            continue :state_loop;
                        },

                        '\r' => {
                            self.cursor += 1;
                            if (self.cursor < self.input.len and self.input[self.cursor] == '\n') {
                                if (self.diagnostics) |diag| {
                                    diag.line_number += 1;
                                    diag.line_start_cursor = self.cursor;
                                }
                                self.cursor += 1;
                            }
                            self.value_start = self.cursor;
                            self.state = .string;
                            continue :state_loop;
                        },

                        else => {
                            self.value_start = self.cursor;
                            self.cursor += 1;
                            self.state = .string;
                            continue :state_loop;
                        },
                    }
                },

                .string_backslash_x_1 => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();

                    const c = self.input[self.cursor];
                    self.hex_byte = (parseHexDigit(c) catch return error.SyntaxError) << 4;
                    self.cursor += 1;
                    self.state = .string_backslash_x_2;
                    continue :state_loop;
                },
                .string_backslash_x_2 => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();

                    const c = self.input[self.cursor];
                    self.hex_byte |= parseHexDigit(c) catch return error.SyntaxError;
                    self.cursor += 1;
                    self.value_start = self.cursor;
                    self.state = .string;
                    return Token{ .partial_string_escaped_1 = [_]u8{self.hex_byte} };
                },

                .string_backslash_u => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    self.utf16_code_units[0] = @as(u16, try parseHexDigit(self.input[self.cursor])) << 12;
                    self.cursor += 1;
                    self.state = .string_backslash_u_1;
                    continue :state_loop;
                },
                .string_backslash_u_1 => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    self.utf16_code_units[0] |= @as(u16, try parseHexDigit(self.input[self.cursor])) << 8;
                    self.cursor += 1;
                    self.state = .string_backslash_u_2;
                    continue :state_loop;
                },
                .string_backslash_u_2 => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    self.utf16_code_units[0] |= @as(u16, try parseHexDigit(self.input[self.cursor])) << 4;
                    self.cursor += 1;
                    self.state = .string_backslash_u_3;
                    continue :state_loop;
                },
                .string_backslash_u_3 => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    self.utf16_code_units[0] |= @as(u16, try parseHexDigit(self.input[self.cursor]));
                    self.cursor += 1;

                    if (std.unicode.utf16IsHighSurrogate(self.utf16_code_units[0])) {
                        self.state = .string_surrogate_half;
                        continue :state_loop;
                    } else if (std.unicode.utf16IsLowSurrogate(self.utf16_code_units[0])) {
                        return error.SyntaxError;
                    } else {
                        self.value_start = self.cursor;
                        self.state = .string;
                        return partialStringCodepoint(self.utf16_code_units[0]);
                    }
                },

                .string_surrogate_half => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    if (self.input[self.cursor] == '\\') {
                        self.cursor += 1;
                        self.state = .string_surrogate_half_backslash;
                        continue :state_loop;
                    }
                    return error.SyntaxError;
                },
                .string_surrogate_half_backslash => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    if (self.input[self.cursor] == 'u') {
                        self.cursor += 1;
                        self.state = .string_surrogate_half_backslash_u;
                        continue :state_loop;
                    }
                    return error.SyntaxError;
                },
                .string_surrogate_half_backslash_u => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();

                    const c = self.input[self.cursor];
                    if (c == 'D' or c == 'd') {
                        self.cursor += 1;
                        self.utf16_code_units[1] = 0xD << 12;
                        self.state = .string_surrogate_half_backslash_u_1;
                        continue :state_loop;
                    }
                    return error.SyntaxError;
                },
                .string_surrogate_half_backslash_u_1 => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();

                    const d = try parseHexDigit(self.input[self.cursor]);
                    if (d < 0xC or d > 0xF) return error.SyntaxError;
                    self.utf16_code_units[1] |= @as(u16, d) << 8;
                    self.cursor += 1;
                    self.state = .string_surrogate_half_backslash_u_2;
                    continue :state_loop;
                },
                .string_surrogate_half_backslash_u_2 => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    self.utf16_code_units[1] |= @as(u16, try parseHexDigit(self.input[self.cursor])) << 4;
                    self.cursor += 1;
                    self.state = .string_surrogate_half_backslash_u_3;
                    continue :state_loop;
                },
                .string_surrogate_half_backslash_u_3 => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    self.utf16_code_units[1] |= @as(u16, try parseHexDigit(self.input[self.cursor]));
                    self.cursor += 1;
                    self.value_start = self.cursor;
                    self.state = .string;

                    const code_point = std.unicode.utf16DecodeSurrogatePair(&self.utf16_code_units) catch unreachable;
                    return partialStringCodepoint(code_point);
                },

                .string_utf8_last_byte => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .string;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .string_utf8_second_to_last_byte => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .string_utf8_last_byte;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .string_utf8_second_to_last_byte_guard_against_overlong => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    switch (self.input[self.cursor]) {
                        0xA0...0xBF => {
                            self.cursor += 1;
                            self.state = .string_utf8_last_byte;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .string_utf8_second_to_last_byte_guard_against_surrogate_half => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    switch (self.input[self.cursor]) {
                        0x80...0x9F => {
                            self.cursor += 1;
                            self.state = .string_utf8_last_byte;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .string_utf8_third_to_last_byte => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    switch (self.input[self.cursor]) {
                        0x80...0xBF => {
                            self.cursor += 1;
                            self.state = .string_utf8_second_to_last_byte;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .string_utf8_third_to_last_byte_guard_against_overlong => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    switch (self.input[self.cursor]) {
                        0x90...0xBF => {
                            self.cursor += 1;
                            self.state = .string_utf8_second_to_last_byte;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },
                .string_utf8_third_to_last_byte_guard_against_too_large => {
                    if (self.cursor >= self.input.len) return self.endOfBufferInString();
                    switch (self.input[self.cursor]) {
                        0x80...0x8F => {
                            self.cursor += 1;
                            self.state = .string_utf8_second_to_last_byte;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .literal_t => return self.matchLiteral("rue", .true),
                .literal_f => return self.matchLiteral("alse", .false),
                .literal_n => return self.matchLiteral("ull", .null),
                .literal_inf_n => return self.matchNumberLiteral("nfinity"),
                .literal_nan_a => return self.matchNumberLiteral("aN"),
            }
        }
    }

    pub fn peekNextTokenType(self: *Scanner) PeekError!TokenType {
        state_loop: while (true) {
            switch (self.state) {
                .value => {
                    return switch (try self.skipWhitespaceAndCommentsExpectByte()) {
                        '{' => .object_begin,
                        '[' => .array_begin,
                        '"', '\'' => .string,
                        '-', '+', '.', '0'...'9', 'I', 'N' => .number,
                        't' => .true,
                        'f' => .false,
                        'n' => .null,
                        else => error.SyntaxError,
                    };
                },

                .post_value => {
                    if (try self.skipWhitespaceAndCommentsCheckEnd()) return .end_of_document;

                    const c = self.input[self.cursor];
                    if (self.string_is_object_key) {
                        self.string_is_object_key = false;
                        switch (c) {
                            ':' => {
                                self.cursor += 1;
                                self.state = .value;
                                continue :state_loop;
                            },
                            else => return error.SyntaxError,
                        }
                    }

                    switch (c) {
                        '}' => return .object_end,
                        ']' => return .array_end,
                        ',' => {
                            self.state = switch (self.stack.peek()) {
                                OBJECT_MODE => .object_post_comma,
                                ARRAY_MODE => .array_post_comma,
                            };
                            self.cursor += 1;
                            continue :state_loop;
                        },
                        else => return error.SyntaxError,
                    }
                },

                .object_start, .object_post_comma => {
                    switch (try self.skipWhitespaceAndCommentsExpectByte()) {
                        '"', '\'', 'a'...'z', 'A'...'Z', '_', '$' => return .string,
                        '}' => return .object_end,
                        else => return error.SyntaxError,
                    }
                },

                .array_start, .array_post_comma => {
                    switch (try self.skipWhitespaceAndCommentsExpectByte()) {
                        ']' => return .array_end,
                        else => {
                            self.state = .value;
                            continue :state_loop;
                        },
                    }
                },

                .identifier_key => return .string,

                .number_sign, .number_leading_zero, .number_hex_digit_1, .number_hex, .number_int, .number_dot, .number_post_dot, .number_frac, .number_post_e, .number_post_e_sign, .number_exp, .literal_inf_n, .literal_nan_a => return .number,

                .string, .string_backslash, .string_backslash_x_1, .string_backslash_x_2, .string_backslash_u, .string_backslash_u_1, .string_backslash_u_2, .string_backslash_u_3, .string_surrogate_half, .string_surrogate_half_backslash, .string_surrogate_half_backslash_u, .string_surrogate_half_backslash_u_1, .string_surrogate_half_backslash_u_2, .string_surrogate_half_backslash_u_3, .string_utf8_last_byte, .string_utf8_second_to_last_byte, .string_utf8_second_to_last_byte_guard_against_overlong, .string_utf8_second_to_last_byte_guard_against_surrogate_half, .string_utf8_third_to_last_byte, .string_utf8_third_to_last_byte_guard_against_overlong, .string_utf8_third_to_last_byte_guard_against_too_large => return .string,

                .literal_t => return .true,
                .literal_f => return .false,
                .literal_n => return .null,
            }
        }
    }

    fn matchLiteral(self: *Scanner, expected: []const u8, result_token: Token) !Token {
        for (expected) |exp| {
            const b = try self.expectByte();
            if (b != exp) return error.SyntaxError;
            self.cursor += 1;
        }
        self.state = .post_value;
        return result_token;
    }

    fn matchNumberLiteral(self: *Scanner, expected: []const u8) !Token {
        for (expected) |exp| {
            const b = try self.expectByte();
            if (b != exp) return error.SyntaxError;
            self.cursor += 1;
        }
        self.state = .post_value;
        return Token{ .number = self.takeValueSlice() };
    }

    fn skipWhitespaceAndComments(self: *Scanner) !void {
        while (self.cursor < self.input.len) {
            const c = self.input[self.cursor];
            switch (c) {
                ' ', '\t', '\r', 0x0B, 0x0C => self.cursor += 1,
                '\n' => {
                    if (self.diagnostics) |diag| {
                        diag.line_number += 1;
                        diag.line_start_cursor = self.cursor;
                    }
                    self.cursor += 1;
                },
                '/' => {
                    if (self.cursor + 1 >= self.input.len) {
                        if (self.is_end_of_input) return;
                        return error.BufferUnderrun;
                    }

                    const next_c = self.input[self.cursor + 1];
                    if (next_c == '/') {
                        self.cursor += 2;
                        while (self.cursor < self.input.len) : (self.cursor += 1) {
                            if (self.input[self.cursor] == '\n') {
                                if (self.diagnostics) |diag| {
                                    diag.line_number += 1;
                                    diag.line_start_cursor = self.cursor;
                                }
                                self.cursor += 1;
                                break;
                            }
                        }
                    } else if (next_c == '*') {
                        self.cursor += 2;
                        var closed = false;
                        while (self.cursor + 1 < self.input.len) : (self.cursor += 1) {
                            if (self.input[self.cursor] == '\n') {
                                if (self.diagnostics) |diag| {
                                    diag.line_number += 1;
                                    diag.line_start_cursor = self.cursor;
                                }
                            }
                            if (self.input[self.cursor] == '*' and self.input[self.cursor + 1] == '/') {
                                self.cursor += 2;
                                closed = true;
                                break;
                            }
                        }
                        if (!closed) {
                            if (self.is_end_of_input) return error.UnexpectedEndOfInput;
                            return error.BufferUnderrun;
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn skipWhitespaceAndCommentsExpectByte(self: *Scanner) !u8 {
        try self.skipWhitespaceAndComments();
        return self.expectByte();
    }

    fn skipWhitespaceAndCommentsCheckEnd(self: *Scanner) !bool {
        try self.skipWhitespaceAndComments();
        if (self.cursor >= self.input.len) {
            if (self.is_end_of_input) {
                if (self.stackHeight() == 0) return true;
                return error.UnexpectedEndOfInput;
            }
            return error.BufferUnderrun;
        }
        if (self.stackHeight() == 0) return error.SyntaxError;
        return false;
    }

    fn expectByte(self: *const Scanner) !u8 {
        if (self.cursor < self.input.len) return self.input[self.cursor];
        if (self.is_end_of_input) return error.UnexpectedEndOfInput;
        return error.BufferUnderrun;
    }

    fn takeValueSlice(self: *Scanner) []const u8 {
        const slice = self.input[self.value_start..self.cursor];
        self.value_start = self.cursor;
        return slice;
    }

    fn takeValueSliceMinusTrailingOffset(self: *Scanner, offset: usize) []const u8 {
        if (self.cursor <= self.value_start + offset) return "";
        const slice = self.input[self.value_start .. self.cursor - offset];
        self.value_start = self.cursor;
        return slice;
    }

    fn endOfBufferInNumber(self: *Scanner, allow_end: bool) !Token {
        const slice = self.takeValueSlice();
        if (self.is_end_of_input) {
            if (!allow_end) return error.UnexpectedEndOfInput;
            self.state = .post_value;
            return Token{ .number = slice };
        }
        if (slice.len == 0) return error.BufferUnderrun;
        return Token{ .partial_number = slice };
    }

    fn endOfBufferInString(self: *Scanner) !Token {
        if (self.is_end_of_input) return error.UnexpectedEndOfInput;
        const slice = self.takeValueSliceMinusTrailingOffset(switch (self.state) {
            .string_backslash => 1,
            .string_backslash_x_1 => 2,
            .string_backslash_x_2 => 3,
            .string_backslash_u => 2,
            .string_backslash_u_1 => 3,
            .string_backslash_u_2 => 4,
            .string_backslash_u_3 => 5,
            .string_surrogate_half => 6,
            .string_surrogate_half_backslash => 7,
            .string_surrogate_half_backslash_u => 8,
            .string_surrogate_half_backslash_u_1 => 9,
            .string_surrogate_half_backslash_u_2 => 10,
            .string_surrogate_half_backslash_u_3 => 11,
            else => 0,
        });
        if (slice.len == 0) return error.BufferUnderrun;
        return Token{ .partial_string = slice };
    }
};

fn parseHexDigit(c: u8) error{SyntaxError}!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.SyntaxError,
    };
}

fn partialStringCodepoint(code_point: u21) Token {
    var buf: [4]u8 = undefined;
    return switch (std.unicode.utf8Encode(code_point, &buf) catch unreachable) {
        1 => Token{ .partial_string_escaped_1 = buf[0..1].* },
        2 => Token{ .partial_string_escaped_2 = buf[0..2].* },
        3 => Token{ .partial_string_escaped_3 = buf[0..3].* },
        4 => Token{ .partial_string_escaped_4 = buf[0..4].* },
        else => unreachable,
    };
}

fn appendSlice(allocator: Allocator, list: *std.ArrayList(u8), buf: []const u8, max_value_len: usize) !void {
    const new_len = std.math.add(usize, list.items.len, buf.len) catch return error.ValueTooLong;
    if (new_len > max_value_len) return error.ValueTooLong;
    try list.appendSlice(allocator, buf);
}

test "json5 parsing features" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const json5_doc =
        \\// Top level comment
        \\{
        \\  /* Multi-line
        \\     comment */
        \\  unquoted_key: 'single-quoted string',
        \\  hex: 0xdecaf,
        \\  pos_float: +1.5,
        \\  lead_dot: .75,
        \\  trail_dot: 42.,
        \\  inf: Infinity,
        \\  nan: -NaN,
        \\  escapes: '\v\0\x41',
        \\  trailing_arr: [ 1, 2, 3, ],
        \\}
    ;

    var scanner = Scanner.initCompleteInput(allocator, json5_doc);
    defer scanner.deinit();

    try testing.expectEqual(.object_begin, try scanner.next());

    // unquoted_key
    try testing.expectEqualStrings("unquoted_key", (try scanner.next()).string);
    try testing.expectEqualStrings("single-quoted string", (try scanner.next()).string);

    // hex
    try testing.expectEqualStrings("hex", (try scanner.next()).string);
    try testing.expectEqualStrings("0xdecaf", (try scanner.next()).number);

    // pos_float
    try testing.expectEqualStrings("pos_float", (try scanner.next()).string);
    try testing.expectEqualStrings("+1.5", (try scanner.next()).number);

    // lead_dot
    try testing.expectEqualStrings("lead_dot", (try scanner.next()).string);
    try testing.expectEqualStrings(".75", (try scanner.next()).number);

    // trail_dot
    try testing.expectEqualStrings("trail_dot", (try scanner.next()).string);
    try testing.expectEqualStrings("42.", (try scanner.next()).number);

    // inf
    try testing.expectEqualStrings("inf", (try scanner.next()).string);
    try testing.expectEqualStrings("Infinity", (try scanner.next()).number);

    // nan
    try testing.expectEqualStrings("nan", (try scanner.next()).string);
    try testing.expectEqualStrings("-NaN", (try scanner.next()).number);

    // escapes ('\v\0\x41' -> VT + NUL + 'A')
    try testing.expectEqualStrings("escapes", (try scanner.next()).string);
    const escaped_tok = try scanner.nextAlloc(allocator, .alloc_always);
    defer allocator.free(escaped_tok.allocated_string);
    try testing.expectEqualStrings("\x0B\x00A", escaped_tok.allocated_string);

    // trailing_arr
    try testing.expectEqualStrings("trailing_arr", (try scanner.next()).string);
    try testing.expectEqual(.array_begin, try scanner.next());
    try testing.expectEqualStrings("1", (try scanner.next()).number);
    try testing.expectEqualStrings("2", (try scanner.next()).number);
    try testing.expectEqualStrings("3", (try scanner.next()).number);
    try testing.expectEqual(.array_end, try scanner.next());

    try testing.expectEqual(.object_end, try scanner.next());
    try testing.expectEqual(.end_of_document, try scanner.next());
}
