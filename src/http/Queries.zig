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

const std = @import("std");
const mem = std.mem;
const ArenaAllocator = std.heap.ArenaAllocator;
