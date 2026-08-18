pub const Cookie = @This();

name: []const u8,
value: []const u8,
path: ?[]const u8 = null,
domain: ?[]const u8 = null,
expires: ?Date = null,
max_age: ?u32 = null,
secure: bool = false,
http_only: bool = false,
same_site: ?SameSite = null,

pub fn init(name: []const u8, value: []const u8) Cookie {
    return .{
        .name = name,
        .value = value,
    };
}

pub const SameSite = enum {
    strict,
    lax,
    none,

    pub fn to_string(same_site: SameSite) []const u8 {
        return switch (same_site) {
            .strict => "Strict",
            .lax => "Lax",
            .none => "None",
        };
    }
};

// TODO: `to_string_buf` and its alloc variant have duplicated implementation
// with the only variation been the `Io` implementation
pub fn to_string_buf(cookie: Cookie, buf: []u8) ![]const u8 {
    const writer: Io.Writer = .fixed(buf);

    try writer.print("{s}={s}", .{ cookie.name, cookie.value });
    if (cookie.domain) |domain|
        try writer.print("; Domain={s}", .{domain});
    if (cookie.path) |path|
        try writer.print("; Path={s}", .{path});
    if (cookie.expires) |exp| {
        try writer.writeAll("; Expires=");
        try exp.to_http_date().into_writer(&writer);
    }
    if (cookie.max_age) |age| try writer.print("; Max-Age={d}", .{age});
    if (cookie.same_site) |same_site| try writer.print(
        "; SameSite={s}",
        .{same_site.to_string()},
    );
    if (cookie.secure) try writer.writeAll("; Secure");
    if (cookie.http_only) try writer.writeAll("; HttpOnly");

    return writer.buffered();
}

pub fn to_string_alloc(cookie: Cookie, allocator: mem.Allocator) ![]const u8 {
    var aw: Io.Writer.Allocating = try .initCapacity(
        allocator,
        128,
    );
    errdefer aw.deinit();
    const writer = &aw.writer;

    try writer.print("{s}={s}", .{ cookie.name, cookie.value });
    if (cookie.domain) |domain|
        try writer.print("; Domain={s}", .{domain});
    if (cookie.path) |path|
        try writer.print("; Path={s}", .{path});
    if (cookie.expires) |exp| {
        try writer.writeAll("; Expires=");
        try exp.to_http_date().into_writer(writer);
    }
    if (cookie.max_age) |age| try writer.print("; Max-Age={d}", .{age});
    if (cookie.same_site) |same_site| try writer.print(
        "; SameSite={s}",
        .{same_site.to_string()},
    );
    if (cookie.secure) try writer.writeAll("; Secure");
    if (cookie.http_only) try writer.writeAll("; HttpOnly");

    return try aw.toOwnedSlice();
}

pub const Map = struct {
    map: std.StringHashMapUnmanaged([]const u8),

    pub const empty: Map = .{
        .map = .empty,
    };

    pub fn deinit(map: *Map, gpa: mem.Allocator) void {
        var iter = map.map.iterator();
        while (iter.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        map.map.deinit(gpa);
    }

    pub fn clear(map: *Map, gpa: mem.Allocator) void {
        var iter = map.map.iterator();
        while (iter.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        map.map.clearRetainingCapacity();
    }

    pub fn get(map: Map, name: []const u8) ?[]const u8 {
        return map.map.get(name);
    }

    pub fn count(map: Map) usize {
        return map.map.count();
    }

    pub fn iterator(map: *const Map) std.StringHashMapUnmanaged([]const u8).Iterator {
        return map.map.iterator();
    }

    // For parsing request cookies (simple key=value pairs)
    pub fn parse_from_header(
        map: *Map,
        gpa: mem.Allocator,
        cookie_header: []const u8,
    ) !void {
        map.clear(gpa);

        var pairs = mem.splitSequence(
            u8,
            cookie_header,
            "; ",
        );
        while (pairs.next()) |pair| {
            var kv = mem.splitScalar(
                u8,
                pair,
                '=',
            );
            const key = kv.next() orelse continue;
            const value = kv.rest();

            const key_dup = try gpa.dupe(u8, key);
            errdefer gpa.free(key_dup);
            const value_dup = try gpa.dupe(u8, value);
            errdefer gpa.free(value_dup);

            if (try map.map.fetchPut(
                gpa,
                key_dup,
                value_dup,
            )) |existing| {
                gpa.free(existing.key);
                gpa.free(existing.value);
            }
        }
    }
};

test "Cookie: Header Parsing" {
    const gpa = testing.allocator;
    var cookie_map: Cookie.Map = .empty;
    defer cookie_map.deinit(gpa);

    try cookie_map.parse_from_header(
        gpa,
        "sessionId=abc123; java=slop; foo=bar=baz",
    );
    try testing.expectEqualStrings(
        "abc123",
        cookie_map.get("sessionId").?,
    );
    try testing.expectEqualStrings("slop", cookie_map.get("java").?);
    try testing.expectEqualStrings("bar=baz", cookie_map.get("foo").?);
}

test "Cookie: Response Formatting" {
    const cookie: Cookie = .{
        .name = "session",
        .value = "abc123",
        .path = "/",
        .domain = "example.com",
        .secure = true,
        .http_only = true,
        .same_site = .strict,
        .max_age = 3600,
    };

    const gpa = testing.allocator;
    const formatted = try cookie.to_string_alloc(gpa);
    defer gpa.free(formatted);

    try testing.expectEqualStrings(
        "session=abc123; Domain=example.com; Path=/; Max-Age=3600; SameSite=Strict; Secure; HttpOnly",
        formatted,
    );
}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const Io = std.Io;

const Date = @import("Date.zig");
