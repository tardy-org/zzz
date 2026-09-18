//! This Trie is deleteless. It only can create new routes or update existing ones
pub const Trie = @This();

root: Node,
middlewares: std.ArrayList(Middleware.WithData),

/// Initialize the routing tree with the given routes.
pub fn init(gpa: mem.Allocator, layers: []const Middleware.Layer) !Trie {
    var trie: Trie = .{
        .root = .init(null),
        .middlewares = .empty,
    };

    for (layers) |layer| switch (layer) {
        .route => |route| {
            var current = &trie.root;
            var iter = mem.tokenizeScalar(
                u8,
                route.path,
                '/',
            );

            while (iter.next()) |chunk| {
                const token: Token = .parse(chunk);
                if (current.tokens.getPtr(token)) |child| {
                    current = child;
                } else {
                    try current.tokens.put(
                        gpa,
                        token,
                        .init(null),
                    );
                    current = current.tokens.getPtr(token).?;
                }
            }

            const current_route: *Route = if (current.route) |*current_route|
                current_route
            else blk: {
                current.route = route;
                break :blk &current.route.?;
            };

            for (route.handlers, 0..) |handler, methods|
                if (handler) |h| {
                    current_route.handlers[methods] = .{
                        .func = h.func,
                        .args = h.args,
                        .middlewares = trie.middlewares.items,
                    };
                };
        },
        .middleware => |mw| try trie.middlewares.append(
            gpa,
            mw,
        ),
    };

    return trie;
}

pub fn deinit(trie: *Trie, gpa: mem.Allocator) void {
    trie.root.deinit(gpa);
    trie.middlewares.deinit(gpa);
}

pub fn bundle(
    trie: Trie,
    gpa: mem.Allocator,
    path: []const u8,
    captures: []Capture,
    queries: *http.Queries,
) !?Bundle {
    const query_pos = mem.findScalar(u8, path, '?');
    var iter = mem.tokenizeScalar(
        u8,
        path[0..(query_pos orelse path.len)],
        '/',
    );

    var capture_idx: usize = 0;
    var current = trie.root;

    chunk_loop: while (iter.next()) |chunk| {
        var tokens_iter = current.tokens.iterator();
        token_loop: while (tokens_iter.next()) |entry| {
            const token = entry.key_ptr.*;
            const child = entry.value_ptr.*;

            switch (token) {
                .fragment => |fragment| if (mem.eql(
                    u8,
                    fragment,
                    chunk,
                )) {
                    current = child;
                    continue :chunk_loop;
                },
                .match => |match| {
                    switch (match) {
                        .signed => {
                            const value = fmt.parseInt(
                                i64,
                                chunk,
                                10,
                            ) catch continue :token_loop;
                            captures[capture_idx] = .{ .signed = value };
                        },
                        .unsigned => {
                            const value = fmt.parseInt(
                                u64,
                                chunk,
                                10,
                            ) catch continue :token_loop;
                            captures[capture_idx] = .{
                                .unsigned = value,
                            };
                        },
                        // Float types MUST have a '.' to differentiate them.
                        .float => {
                            _ = mem.findScalar(u8, chunk, '.') orelse continue :token_loop;

                            const value = fmt.parseFloat(
                                f64,
                                chunk,
                            ) catch continue :token_loop;
                            captures[capture_idx] = .{
                                .float = value,
                            };
                        },
                        .string => captures[capture_idx] = .{
                            .string = chunk,
                        },
                        .remaining => {
                            const rest =
                                iter.buffer[(iter.index - chunk.len)..];
                            captures[capture_idx] = .{
                                .remaining = rest,
                            };

                            current = child;
                            capture_idx += 1;

                            break :chunk_loop;
                        },
                    }

                    current = child;
                    capture_idx += 1;

                    debug.assert(capture_idx <= captures.len);

                    continue :chunk_loop;
                },
            }
        }

        // If we failed to match, this is an invalid route.
        return null;
    }

    if (query_pos) |pos| {
        try urlDecoding(gpa, path[pos + 1 ..], queries);
    }

    return .{
        .route = current.route orelse return null,
        .captures = captures[0..capture_idx],
        .queries = queries,
    };
}

// https://url.spec.whatwg.org/#urlencoded-parsing
fn urlDecoding(
    gpa: mem.Allocator,
    url: []const u8,
    queries: *http.Queries,
) !void {
    if (url.len == 0) return;
    debug.assert(url[0] != '?');

    var query_iter = mem.tokenizeScalar(
        u8,
        url[0..],
        '&',
    );

    var arena_alloc = queries.arena_state.promote(gpa);
    const arena = arena_alloc.allocator();

    while (query_iter.next()) |chunk| {
        const field_idx = mem.findScalar(
            u8,
            chunk,
            '=',
        ) orelse return error.MissingValue;

        const hex_bytes_size = 2;
        if (chunk.len < field_idx + hex_bytes_size) return error.MissingValue;

        const key = chunk[0..field_idx];
        const value = chunk[(field_idx + 1)..];

        if (mem.findScalar(u8, value, '=') != null)
            return error.MalformedPair;

        const decoded_key, const decoded_value = blk: {
            // Update `arena_state` here to ensure we don't lose track of any
            // of the allocations below since `queries.put` also modifies the state
            defer queries.arena_state = arena_alloc.state;

            const decoded_key = try form.percentDecode(
                arena,
                key,
            );

            const decoded_value = try form.percentDecode(
                arena,
                value,
            );

            break :blk .{ decoded_key, decoded_value };
        };

        // Later values will clobber earlier ones.
        try queries.put(gpa, decoded_key, decoded_value);
    }
}

fn TokenHashMap(comptime V: type) type {
    return std.HashMapUnmanaged(Token, V, struct {
        pub fn hash(_: @This(), input: Token) u64 {
            const bytes: []const u8 = blk: {
                switch (input) {
                    .fragment => |fragment| break :blk fragment,
                    .match => |match| break :blk @tagName(match),
                }
            };

            return Wyhash.hash(0, bytes);
        }

        pub fn eql(_: @This(), first: Token, second: Token) bool {
            const result = blk: {
                switch (first) {
                    .fragment => |fragment_1| {
                        switch (second) {
                            .fragment => |fragment_2| break :blk mem.eql(
                                u8,
                                fragment_1,
                                fragment_2,
                            ),
                            else => break :blk false,
                        }
                    },
                    .match => |match_1| {
                        switch (second) {
                            .match => |match_2| break :blk match_1 == match_2,
                            else => break :blk false,
                        }
                    },
                }
            };

            return result;
        }
    }, std.hash_map.default_max_load_percentage);
}

/// Structure of a node of the trie.
pub const Node = struct {
    route: ?Route = null,
    tokens: TokenHashMap(Node),

    /// Initialize a new empty node.
    pub fn init(route: ?Route) Node {
        return .{
            .route = route,
            .tokens = .empty,
        };
    }

    pub fn deinit(node: *Node, gpa: mem.Allocator) void {
        var iter = node.tokens.valueIterator();

        while (iter.next()) |next_node| next_node.deinit(gpa);

        node.tokens.deinit(gpa);
    }
};

/// Structure of a matched route.
pub const Bundle = struct {
    route: Route,
    captures: []const Capture,
    queries: *http.Queries,
};

pub const Capture = union(Token.Match) {
    unsigned: Token.Match.unsigned.toType(),
    signed: Token.Match.signed.toType(),
    float: Token.Match.float.toType(),
    string: Token.Match.string.toType(),
    remaining: Token.Match.remaining.toType(),
};

test "Constructing Routing from Path" {
    const gpa = testing.allocator;
    var routes: Trie = try .init(gpa, &.{
        Route.init("/item").layer(),
        Route.init("/item/%i/description").layer(),
        Route.init("/item/%i/hello").layer(),
        Route.init("/item/%f/price_float").layer(),
        Route.init("/item/name/%s").layer(),
        Route.init("/item/list").layer(),
    });
    defer routes.deinit(gpa);

    try testing.expectEqual(1, routes.root.tokens.count());
}

test "Routing with Paths" {
    const gpa = testing.allocator;
    var routes: Trie = try .init(gpa, &.{
        Route.init("/item").layer(),
        Route.init("/item/%i/description").layer(),
        Route.init("/item/%i/hello").layer(),
        Route.init("/item/%f/price_float").layer(),
        Route.init("/item/name/%s").layer(),
        Route.init("/item/list").layer(),
    });
    defer routes.deinit(gpa);

    var queries: http.Queries = .empty;
    defer queries.deinit(gpa);

    var captures: [8]Capture = @splat(undefined);

    try testing.expectEqual(null, try routes.bundle(
        gpa,
        "/item/name",
        &captures,
        &queries,
    ));

    {
        const captured = (try routes.bundle(
            gpa,
            "/item/name/HELLO",
            &captures,
            &queries,
        )).?;

        try testing.expectEqual(
            Route.init("/item/name/%s"),
            captured.route,
        );
        try testing.expectEqualStrings(
            "HELLO",
            captured.captures[0].string,
        );
    }

    {
        const captured = (try routes.bundle(
            gpa,
            "/item/2112.22121/price_float",
            &captures,
            &queries,
        )).?;

        try testing.expectEqual(
            Route.init("/item/%f/price_float"),
            captured.route,
        );
        try testing.expectEqual(
            2112.22121,
            captured.captures[0].float,
        );
    }
}

test "Routing with Remaining" {
    const gpa = testing.allocator;
    var routes: Trie = try .init(gpa, &.{
        Route.init("/item").layer(),
        Route.init("/item/%f/price_float").layer(),
        Route.init("/item/name/%r").layer(),
        Route.init("/item/%i/price/%f").layer(),
    });
    defer routes.deinit(gpa);

    var queries: http.Queries = .empty;
    defer queries.deinit(gpa);

    var captures: [8]Capture = @splat(undefined);

    try testing.expectEqual(
        null,
        try routes.bundle(
            gpa,
            "/item/name",
            &captures,
            &queries,
        ),
    );

    {
        const captured = (try routes.bundle(
            gpa,
            "/item/name/HELLO",
            &captures,
            &queries,
        )).?;
        try testing.expectEqual(
            Route.init("/item/name/%r"),
            captured.route,
        );
        try testing.expectEqualStrings(
            "HELLO",
            captured.captures[0].remaining,
        );
    }
    {
        const captured = (try routes.bundle(
            gpa,
            "/item/name/THIS/IS/A/FILE/SYSTEM/PATH.html",
            &captures,
            &queries,
        )).?;
        try testing.expectEqual(
            Route.init("/item/name/%r"),
            captured.route,
        );
        try testing.expectEqualStrings(
            "THIS/IS/A/FILE/SYSTEM/PATH.html",
            captured.captures[0].remaining,
        );
    }

    {
        const captured = (try routes.bundle(
            gpa,
            "/item/2112.22121/price_float",
            &captures,
            &queries,
        )).?;
        try testing.expectEqual(
            Route.init("/item/%f/price_float"),
            captured.route,
        );
        try testing.expectEqual(2112.22121, captured.captures[0].float);
    }

    {
        const captured = (try routes.bundle(
            gpa,
            "/item/100/price/283.21",
            &captures,
            &queries,
        )).?;
        try testing.expectEqual(
            Route.init("/item/%i/price/%f"),
            captured.route,
        );
        try testing.expectEqual(100, captured.captures[0].signed);
        try testing.expectEqual(283.21, captured.captures[1].float);
    }
}

test "Routing with Queries" {
    const gpa = testing.allocator;
    var routes: Trie = try .init(gpa, &.{
        Route.init("/item").layer(),
        Route.init("/item/%f/price_float").layer(),
        Route.init("/item/name/%r").layer(),
        Route.init("/item/%i/price/%f").layer(),
    });
    defer routes.deinit(gpa);

    var queries: http.Queries = .empty;
    defer queries.deinit(gpa);

    var captures: [8]Capture = @splat(undefined);

    try testing.expectEqual(null, try routes.bundle(
        gpa,
        "/item/name",
        &captures,
        &queries,
    ));

    {
        queries.clear(gpa);
        const captured = (try routes.bundle(
            gpa,
            "/item/name/HELLO?name=muki&food=waffle",
            &captures,
            &queries,
        )).?;

        try testing.expectEqual(
            Route.init("/item/name/%r"),
            captured.route,
        );
        try testing.expectEqualStrings(
            "HELLO",
            captured.captures[0].remaining,
        );
        try testing.expectEqual(2, queries.map.count());
        try testing.expectEqualStrings("muki", queries.get("name").?);
        try testing.expectEqualStrings("waffle", queries.get("food").?);
    }

    {
        queries.clear(gpa);
        // Purposefully bad format with no keys or values.
        const captured = (try routes.bundle(
            gpa,
            "/item/2112.22121/price_float?",
            &captures,
            &queries,
        )).?;

        try testing.expectEqual(
            Route.init("/item/%f/price_float"),
            captured.route,
        );
        try testing.expectEqual(2112.22121, captured.captures[0].float);
        try testing.expectEqual(0, queries.map.count());
    }

    {
        queries.clear(gpa);
        // Purposefully bad format with incomplete key/value pair.
        const captured = routes.bundle(
            gpa,
            "/item/100/price/283.21?help",
            &captures,
            &queries,
        );
        try testing.expectError(
            error.MissingValue,
            captured,
        );
    }

    {
        queries.clear(gpa);
        // Purposefully bad format with incomplete key/value pair.
        const captured = routes.bundle(
            gpa,
            "/item/100/price/283.21?help=",
            &captures,
            &queries,
        );
        try testing.expectError(
            error.MissingValue,
            captured,
        );
    }

    {
        queries.clear(gpa);
        // Purposefully bad format with invalid charactes.
        const captured = routes.bundle(
            gpa,
            "/item/999/price/100.221?page_count=pages=2020&abc=200",
            &captures,
            &queries,
        );
        try testing.expectError(
            error.MalformedPair,
            captured,
        );
    }
}

const log = std.log.scoped(.@"zzz/http/routing_trie");

const std = @import("std");
const Wyhash = std.hash.Wyhash;
const mem = std.mem;
const fmt = std.fmt;
const debug = std.debug;
const testing = std.testing;

const zzz = @import("zzz");
const http = zzz.http;
const form = zzz.http.form;
const Middleware = @import("Middleware.zig");
const Route = @import("Route.zig");
const Token = @import("token.zig").Token;
