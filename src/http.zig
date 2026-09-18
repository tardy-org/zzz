const std = @import("std");
const testing = std.testing;
const debug = std.debug;
const fmt = std.fmt;
const mem = std.mem;

pub const Context = @import("http/Context.zig");
pub const Cookie = @import("http/Cookie.zig");
pub const Date = @import("http/Date.zig");
pub const form = @import("http/form.zig");
pub const Headers = @import("http/header.zig").Headers;
pub const Method = @import("http/method.zig").Method;
pub const middleware = @import("http/middleware.zig");
pub const Mime = @import("http/Mime.zig");
pub const Queries = @import("http/Queries.zig");
pub const Request = @import("http/Request.zig");
pub const Response = @import("http/Response.zig");
pub const Router = @import("http/Router.zig");
pub const Server = @import("http/Server.zig");
pub const SSE = @import("http/SSE.zig");
pub const Status = @import("http/status.zig").Status;

pub const Version = enum {
    @"HTTP/1.1",
};

pub const Respond = enum {
    // When we are returning a real HTTP request, we use this.
    standard,
    // If we responded and we want to give control back to the HTTP engine.
    responded,
    // If we want the connection to close.
    close,
};

pub const Compression = enum {
    gzip,
    compress,
    deflate,
    br,
    zstd,
};

pub const Error = error{
    TooManyHeaders,
    ContentTooLarge,
    MalformedRequest,
    InvalidMethod,
    InvalidURI,
    URITooLong,
    UnSupportedHTTPVersion,
};

/// https://url.spec.whatwg.org/#percent-decode
/// Caller owns the returned memory and must free it
pub fn percentDecode(gpa: mem.Allocator, input: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = try .initCapacity(gpa, input.len);
    defer list.deinit(gpa);

    var input_index: usize = 0;
    while (input_index < input.len) : (input_index += 1) {
        const byte = input[input_index];
        switch (byte) {
            '%' => {
                const hex_bytes_size = 2;
                debug.assert(input_index + hex_bytes_size < input.len);

                const next_hex =
                    input[input_index + 1 ..][0..hex_bytes_size];

                switch (next_hex[0]) {
                    // 0...9, A...F, a...f
                    0x30...0x39, 0x41...0x46, 0x61...0x66 => {
                        switch (next_hex[1]) {
                            0x30...0x39, 0x41...0x46, 0x61...0x66 => {
                                const next_byte = try fmt.parseInt(
                                    u8,
                                    next_hex,
                                    16,
                                );
                                defer input_index += hex_bytes_size;

                                list.appendAssumeCapacity(next_byte);
                            },
                            else => {
                                list.appendAssumeCapacity(byte);
                            },
                        }
                    },
                    else => {
                        list.appendAssumeCapacity(byte);
                    },
                }
            },
            '+' => list.appendAssumeCapacity(' '),
            else => list.appendAssumeCapacity(byte),
        }
    }

    try list.shrinkToLen(gpa);

    return list.toOwnedSliceAssert();
}

test percentDecode {
    const gpa = testing.allocator;

    const inputs: [2]struct { []const u8, []const u8 } = .{
        .{ "%25%s%1G", "%%s%1G" },
        .{ "‽%25%2E", &.{ 0xE2, 0x80, 0xBD, 0x25, 0x2E } },
    };

    for (inputs) |tests_values| {
        const input, const expected = tests_values;
        const actual = try percentDecode(gpa, input);
        defer gpa.free(actual);

        try testing.expectEqualSlices(u8, expected[0..], actual);
    }
}

test {
    std.testing.refAllDecls(@This());
}
