pub const Storage = @This();

arena_state: heap.ArenaAllocator.State,
map: std.AutoHashMapUnmanaged(
    Key,
    *anyopaque,
),

pub const empty: Storage = .{
    .arena_state = .init,
    .map = .empty,
};

pub fn deinit(storage: *Storage, gpa: mem.Allocator) void {
    var arena_alloc = storage.arena_state.promote(gpa);
    storage.map.deinit(arena_alloc.allocator());
    arena_alloc.deinit();
}

/// Clears the Storage.
pub fn clear(storage: *Storage, gpa: mem.Allocator) void {
    var arena_alloc = storage.arena_state.promote(gpa);
    defer storage.arena_state = arena_alloc.state;

    storage.map.clearAndFree(arena_alloc.allocator());
    _ = arena_alloc.reset(.retain_capacity);
}

/// Inserts a value into the Storage.
/// It uses the given type as the K.
pub fn put(storage: *Storage, gpa: mem.Allocator, comptime T: type, value: T) !void {
    var arena_alloc = storage.arena_state.promote(gpa);
    defer storage.arena_state = arena_alloc.state;

    const arena = arena_alloc.allocator();
    const ptr = try arena.create(T);
    ptr.* = value;
    const type_id = comptime hash.Wyhash.hash(0, @typeName(T));
    try storage.map.put(arena, type_id, @ptrCast(ptr));
}

/// Extracts a value out of the Storage.
/// It uses the given type as the K.
pub fn get(storage: *Storage, comptime T: type) ?T {
    const type_id = comptime hash.Wyhash.hash(0, @typeName(T));
    const ptr = storage.map.get(type_id) orelse return null;
    return @as(*T, @ptrCast(@alignCast(ptr))).*;
}

test "Storage: Basic" {
    const gpa = testing.allocator;
    var storage: Storage = .empty;
    defer storage.deinit(gpa);

    // Test inserting and getting different types
    try storage.put(gpa, u32, 42);
    try storage.put(gpa, []const u8, "hello");
    try storage.put(gpa, f32, 3.14);

    try testing.expectEqual(42, storage.get(u32).?);
    try testing.expectEqualStrings("hello", storage.get([]const u8).?);
    try testing.expectEqual(3.14, storage.get(f32).?);

    // Test overwriting a value
    try storage.put(gpa, u32, 100);
    try testing.expectEqual(100, storage.get(u32).?);

    // Test getting non-existent type
    try testing.expectEqual(null, storage.get(bool));

    // Test clearing
    storage.clear(gpa);
    try testing.expectEqual(null, storage.get(u32));
    try testing.expectEqual(null, storage.get([]const u8));
    try testing.expectEqual(null, storage.get(f32));

    // Test inserting after clear
    try storage.put(gpa, u32, 200);
    try testing.expectEqual(200, storage.get(u32).?);
}

const Key = u64;

const std = @import("std");
const testing = std.testing;
const heap = std.heap;
const hash = std.hash;
const ascii = std.ascii;
const mem = std.mem;
