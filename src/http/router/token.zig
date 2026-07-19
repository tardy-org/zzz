pub const Token = union(Enum) {
    fragment: []const u8,
    match: Match,

    pub const Match = enum {
        unsigned,
        signed,
        float,
        string,
        remaining,

        pub fn as_type(match: Match) type {
            switch (match) {
                .unsigned => return u64,
                .signed => return i64,
                .float => return f64,
                .string => return []const u8,
                .remaining => return []const u8,
            }
        }
    };

    const Enum = enum(u8) {
        fragment = 0,
        match = 1,
    };

    pub fn parse_chunk(chunk: []const u8) Token {
        if (mem.startsWith(u8, chunk, "%")) {
            // Needs to be only % and an identifier.
            debug.assert(chunk.len == 2);

            switch (chunk[1]) {
                'i', 'd' => return .{ .match = .signed },
                'u' => return .{ .match = .unsigned },
                'f' => return .{ .match = .float },
                's' => return .{ .match = .string },
                'r' => return .{ .match = .remaining },
                else => @panic("Unsupported Match!"),
            }
        } else {
            return .{ .fragment = chunk };
        }
    }
};

test "Chunk Parsing (Fragment)" {
    const chunk = "thisIsAFragment";
    const token: Token = .parse_chunk(chunk);

    switch (token) {
        .fragment => |inner| try testing.expectEqualStrings(
            chunk,
            inner,
        ),
        .match => return error.IncorrectTokenParsing,
    }
}

test "Chunk Parsing (Match)" {
    const chunks: [5][]const u8 = .{
        "%i",
        "%d",
        "%u",
        "%f",
        "%s",
    };

    const matches: [5]Token.Match = .{
        .signed,
        .signed,
        .unsigned,
        .float,
        .string,
    };

    for (chunks, matches) |chunk, match| {
        const token: Token = .parse_chunk(chunk);

        switch (token) {
            .fragment => return error.IncorrectTokenParsing,
            .match => |inner| try testing.expectEqual(
                match,
                inner,
            ),
        }
    }
}

test "Path Parsing (Mixed)" {
    const path = "/item/%i/description";

    const parsed: [3]Token = .{
        .{ .fragment = "item" },
        .{ .match = .signed },
        .{ .fragment = "description" },
    };

    var iter = mem.tokenizeScalar(u8, path, '/');

    for (parsed) |expected| {
        const token: Token = .parse_chunk(iter.next().?);
        switch (token) {
            .fragment => |inner| try testing.expectEqualStrings(
                expected.fragment,
                inner,
            ),
            .match => |inner| try testing.expectEqual(
                expected.match,
                inner,
            ),
        }
    }
}

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;
