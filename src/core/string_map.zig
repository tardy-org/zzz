pub const AnyCase = std.HashMapUnmanaged(
    []const u8,
    []const u8,
    // needed because the comparision ignores case
    Context,
    std.hash_map.default_max_load_percentage,
);

const Context = struct {
    pub fn hash(_: Context, key: []const u8) u64 {
        var hasher: std.hash.Wyhash = .init(0);
        for (key) |byte| hasher.update(mem.asBytes(&ascii.toLower(byte)));
        return hasher.final();
    }

    pub fn eql(_: Context, key_a: []const u8, key_b: []const u8) bool {
        return ascii.eqlIgnoreCase(key_a, key_b);
    }
};

test "string_map.AnyCase: Add Stuff" {
    const gpa = testing.allocator;
    var map: AnyCase = .empty;
    defer map.deinit(gpa);

    try map.put(gpa, "Content-Length", "100");
    try map.put(gpa, "Host", "localhost:9999");

    const content_length = map.get("Content-length");
    try testing.expect(content_length != null);

    const host = map.get("host");
    try testing.expect(host != null);
}

const std = @import("std");
const mem = std.mem;
const array_hash_map = std.array_hash_map;
const ascii = std.ascii;
const testing = std.testing;
