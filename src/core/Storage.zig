pub const Storage = @This();

arena_state: heap.ArenaAllocator.State,
map: array_hash_map.Custom(
    Key,
    *anyopaque,
    Context,
    false,
),

pub const empty: Storage = .{
    .arena_state = .init,
    .map = .empty,
};

pub fn deinit(storage: *Storage, gpa: mem.Allocator) void {
    const arena = storage.arena_state.promote(gpa);
    storage.map.deinit(arena.allocator());
    arena.deinit();
}

/// Clears the Storage.
pub fn clear(storage: *Storage, gpa: mem.Allocator) void {
    var arena = storage.arena_state.promote(gpa);
    defer storage.arena_state = arena.state;

    storage.map.clearAndFree(arena.allocator());
    _ = arena.reset(.retain_capacity);
}

/// Inserts a value into the Storage.
/// It uses the given type as the K.
pub fn put(storage: *Storage, gpa: mem.Allocator, comptime T: type, value: T) !void {
    var arena = storage.arena_state.promote(gpa);
    defer storage.arena_state = arena.state;

    const allocator = arena.allocator();
    const ptr = try allocator.create(T);
    ptr.* = value;
    const type_id = comptime hash.XxHash3.hash(0, @typeName(T));
    try storage.map.put(allocator, type_id, @ptrCast(ptr));
}

/// Extracts a value out of the Storage.
/// It uses the given type as the K.
pub fn get(storage: *Storage, comptime T: type) ?T {
    const type_id = comptime hash.XxHash3.hash(0, @typeName(T));
    const ptr = storage.map.get(type_id) orelse return null;
    return @as(*T, @ptrCast(@alignCast(ptr))).*;
}

const Context = struct {
    pub fn hash(_: Context, key: Key) u32 {
        const hasher = std.hash.XxHash3.hash(0, &key);
        return @truncate(hasher);
    }

    pub fn eql(_: Context, key_a: Key, key_b: Key, _: usize) bool {
        return key_a == key_b;
    }
};

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
const array_hash_map = std.array_hash_map;
