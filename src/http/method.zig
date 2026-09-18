pub const Method = enum(u8) {
    GET = 0,
    HEAD = 1,
    POST = 2,
    PUT = 3,
    DELETE = 4,
    CONNECT = 5,
    OPTIONS = 6,
    TRACE = 7,
    PATCH = 8,

    pub const count = 9;

    pub fn parse(method: []const u8) !Method {
        debug.assert(method.len != 0);
        const encode = meta.stringToEnum(Method, method);
        if (encode) |encode_| return encode_ else {
            log.err("unable to parse http method: {s}", .{method});
            return error.InvalidMethod;
        }
    }
};

test "Parsing Strings" {
    for (meta.tags(Method)) |method| {
        const method_string = @tagName(method);
        try testing.expectEqual(
            method,
            try Method.parse(method_string),
        );
    }
}

const log = std.log.scoped(.@"zzz/http/method");

const std = @import("std");
const debug = std.debug;
const meta = std.meta;
const testing = std.testing;
