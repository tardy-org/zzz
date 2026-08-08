pub const Storage = @This();

// arena: std.heap.ArenaAllocator.State,
arena: std.heap.ArenaAllocator,
map: hash_map.AutoHashMapUnmanaged(
    Hash,
    *anyopaque,
),

pub fn init(allocator: mem.Allocator) Storage {
    return .{
        .arena = .init(allocator),
        .map = .empty,
    };
}

pub fn deinit(storage: *Storage) void {
    storage.map.deinit(storage.arena.allocator());
    storage.arena.deinit();
}

/// Clears the Storage.
pub fn clear(storage: *Storage) void {
    storage.map.clearAndFree(storage.arena.allocator());
    _ = storage.arena.reset(.retain_capacity);
}

/// Inserts a value into the Storage.
/// It uses the given type as the K.
pub fn put(storage: *Storage, comptime T: type, value: T) !void {
    const allocator = storage.arena.allocator();
    const ptr = try allocator.create(T);
    ptr.* = value;
    const type_id = comptime hash.Wyhash.hash(0, @typeName(T));
    try storage.map.put(allocator, type_id, @ptrCast(ptr));
}

/// Extracts a value out of the Storage.
/// It uses the given type as the K.
pub fn get(storage: *Storage, comptime T: type) ?T {
    const type_id = comptime hash.Wyhash.hash(0, @typeName(T));
    const ptr = storage.map.get(type_id) orelse return null;
    return @as(*T, @ptrCast(@alignCast(ptr))).*;
}

test "Storage: Basic" {
    var storage: Storage = .init(testing.allocator);
    defer storage.deinit();

    // Test inserting and getting different types
    try storage.put(u32, 42);
    try storage.put([]const u8, "hello");
    try storage.put(f32, 3.14);

    try testing.expectEqual(42, storage.get(u32).?);
    try testing.expectEqualStrings("hello", storage.get([]const u8).?);
    try testing.expectEqual(3.14, storage.get(f32).?);

    // Test overwriting a value
    try storage.put(u32, 100);
    try testing.expectEqual(100, storage.get(u32).?);

    // Test getting non-existent type
    try testing.expectEqual(null, storage.get(bool));

    // Test clearing
    storage.clear();
    try testing.expectEqual(null, storage.get(u32));
    try testing.expectEqual(null, storage.get([]const u8));
    try testing.expectEqual(null, storage.get(f32));

    // Test inserting after clear
    try storage.put(u32, 200);
    try testing.expectEqual(200, storage.get(u32).?);
}

const Hash = u64;

const std = @import("std");
const testing = std.testing;
const hash = std.hash;
const mem = std.mem;
const hash_map = std.hash_map;
