const Context = struct {
    pub fn hash(_: Context, key: []const u8) u64 {
        var wyhash: std.hash.Wyhash = .init(0);
        for (key) |b| wyhash.update(&.{std.ascii.toLower(b)});
        return wyhash.final();
    }

    pub fn eql(_: Context, key1: []const u8, key2: []const u8) bool {
        if (key1.len != key2.len) return false;
        for (key1, key2) |b1, b2|
            if (std.ascii.toLower(b1) != std.ascii.toLower(b2)) return false;
        return true;
    }
};

pub const AnyCase = std.hash_map.HashMap(
    []const u8,
    []const u8,
    Context,
    80,
);

test "string_map.AnyCase: Add Stuff" {
    var map: AnyCase = .init(testing.allocator);
    defer map.deinit();

    try map.put("Content-Length", "100");
    try map.put("Host", "localhost:9999");

    const content_length = map.get("Content-length");
    try testing.expect(content_length != null);

    const host = map.get("host");
    try testing.expect(host != null);
}

const std = @import("std");
const testing = std.testing;
