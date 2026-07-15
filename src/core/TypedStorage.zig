pub const TypedStorage = @This();

arena: std.heap.ArenaAllocator,
storage: hash_map.AutoHashMapUnmanaged(
    Key,
    *anyopaque,
),

pub fn init(allocator: mem.Allocator) TypedStorage {
    return .{
        .arena = .init(allocator),
        .storage = .empty,
    };
}

pub fn deinit(self: *TypedStorage) void {
    self.arena.deinit();
}

/// Clears the Storage.
pub fn clear(self: *TypedStorage) void {
    self.storage.clearAndFree(self.arena.allocator());
    _ = self.arena.reset(.retain_capacity);
}

/// Inserts a value into the Storage.
/// It uses the given type as the K.
pub fn put(self: *TypedStorage, comptime T: type, value: T) !void {
    const allocator = self.arena.allocator();
    const ptr = try allocator.create(T);
    ptr.* = value;
    const type_id = comptime hash.Wyhash.hash(0, @typeName(T));
    try self.storage.put(allocator, type_id, @ptrCast(ptr));
}

/// Extracts a value out of the Storage.
/// It uses the given type as the K.
pub fn get(self: *TypedStorage, comptime T: type) ?T {
    const type_id = comptime hash.Wyhash.hash(0, @typeName(T));
    const ptr = self.storage.get(type_id) orelse return null;
    return @as(*T, @ptrCast(@alignCast(ptr))).*;
}

test "TypedStorage: Basic" {
    var storage: TypedStorage = .init(testing.allocator);
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

const Key = u64;

const std = @import("std");
const testing = std.testing;
const hash = std.hash;
const mem = std.mem;
const hash_map = std.hash_map;
