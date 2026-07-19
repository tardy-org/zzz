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

    // TODO: Why do we need this and not a simple switch
    fn encode(method: []const u8) u64 {
        var buffer: [@sizeOf(u64)]u8 = @splat(0);
        @memcpy(buffer[0..method.len], method);

        return std.mem.readPackedInt(
            u64,
            buffer[0..],
            0,
            .native,
        );
    }

    pub fn parse(method: []const u8) !Method {
        if (method.len > (comptime @sizeOf(u64)) or method.len == 0) {
            log.warn("unable to encode method: {s}", .{method});
            return error.CannotEncode;
        }

        const encoded = encode(method);

        return switch (encoded) {
            encode("GET") => .GET,
            encode("HEAD") => .HEAD,
            encode("POST") => .POST,
            encode("PUT") => .PUT,
            encode("DELETE") => .DELETE,
            encode("CONNECT") => .CONNECT,
            encode("OPTIONS") => .OPTIONS,
            encode("TRACE") => .TRACE,
            encode("PATCH") => .PATCH,
            else => {
                log.warn("unable to match method: {s} | {d}", .{ method, encoded });
                return error.CannotParse;
            },
        };
    }
};

test "Parsing Strings" {
    for (std.meta.tags(Method)) |method| {
        const method_string = @tagName(method);
        try testing.expectEqual(method, try Method.parse(method_string));
    }
}

const log = std.log.scoped(.@"zzz/http/method");

const std = @import("std");
const testing = std.testing;
