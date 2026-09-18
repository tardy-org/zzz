/// https://datatracker.ietf.org/doc/html/rfc3986/#section-6.2.2.1
/// Queries are case sensitive by default
pub const Queries = @This();

arena_state: ArenaAllocator.State,
map: std.StringHashMapUnmanaged([]const u8),

pub const empty: Queries = .{
    .arena_state = .init,
    .map = .empty,
};

pub fn deinit(queries: *Queries, gpa: mem.Allocator) void {
    var arena_alloc = queries.arena_state.promote(gpa);
    defer queries.arena_state = arena_alloc.state;

    queries.map.deinit(arena_alloc.allocator());
    arena_alloc.deinit();
}

pub fn clear(queries: *Queries, gpa: mem.Allocator) void {
    var arena_alloc = queries.arena_state.promote(gpa);
    defer queries.arena_state = arena_alloc.state;

    queries.map.clearRetainingCapacity();
    _ = arena_alloc.reset(.retain_capacity);
}

pub fn put(
    queries: *Queries,
    gpa: mem.Allocator,
    key: []const u8,
    value: []const u8,
) !void {
    var arena_alloc = queries.arena_state.promote(gpa);
    defer queries.arena_state = arena_alloc.state;

    const arena = arena_alloc.allocator();

    try queries.map.put(arena, key, value);
}

pub fn get(
    queries: *Queries,
    key: []const u8,
) ?[]const u8 {
    return queries.map.get(key);
}

/// https://url.spec.whatwg.org/#urlencoded-parsing
pub fn urlDecoding(
    queries: *Queries,
    gpa: mem.Allocator,
    url: []const u8,
) !void {
    if (url.len == 0) return;
    debug.assert(url[0] != '?');

    var iter = mem.tokenizeScalar(
        u8,
        url[0..],
        '&',
    );

    var arena_alloc = queries.arena_state.promote(gpa);
    const arena = arena_alloc.allocator();

    while (iter.next()) |key_value| {
        const split_idx = mem.findScalar(
            u8,
            key_value,
            '=',
        ) orelse return error.MissingValue;

        const hex_bytes_size = 2;
        if (key_value.len < split_idx + hex_bytes_size) return error.MissingValue;

        const key = key_value[0..split_idx];
        const value = key_value[(split_idx + 1)..];

        if (mem.findScalar(u8, value, '=') != null)
            return error.MalformedPair;

        const decoded_key, const decoded_value = blk: {
            // Update `arena_state` here to ensure we don't lose track of any
            // of the allocations below since `queries.put` also modifies the state
            defer queries.arena_state = arena_alloc.state;

            const decoded_key = try http.percentDecode(
                arena,
                key,
            );
            errdefer arena.free(decoded_key);

            const decoded_value = try http.percentDecode(
                arena,
                value,
            );
            errdefer arena.free(decoded_value);

            break :blk .{ decoded_key, decoded_value };
        };

        // Later values will clobber earlier ones.
        try queries.put(gpa, decoded_key, decoded_value);
    }
}

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const ArenaAllocator = std.heap.ArenaAllocator;

const zzz = @import("zzz");
const http = zzz.http;
