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

    pub fn to_string(self: SameSite) []const u8 {
        return switch (self) {
            .strict => "Strict",
            .lax => "Lax",
            .none => "None",
        };
    }
};

pub fn to_string_buf(self: Cookie, buf: []u8) ![]const u8 {
    const writer: Io.Writer = .fixed(buf);

    try writer.print("{s}={s}", .{ self.name, self.value });
    if (self.domain) |domain| try writer.print("; Domain={s}", .{domain});
    if (self.path) |path| try writer.print("; Path={s}", .{path});
    if (self.expires) |exp| {
        try writer.writeAll("; Expires=");
        try exp.to_http_date().into_writer(&writer);
    }
    if (self.max_age) |age| try writer.print("; Max-Age={d}", .{age});
    if (self.same_site) |same_site| try writer.print(
        "; SameSite={s}",
        .{same_site.to_string()},
    );
    if (self.secure) try writer.writeAll("; Secure");
    if (self.http_only) try writer.writeAll("; HttpOnly");

    return writer.buffered();
}

pub fn to_string_alloc(self: Cookie, allocator: mem.Allocator) ![]const u8 {
    var aw: Io.Writer.Allocating = try .initCapacity(allocator, 128);
    errdefer aw.deinit();
    const writer = &aw.writer;

    try writer.print("{s}={s}", .{ self.name, self.value });
    if (self.domain) |domain| try writer.print("; Domain={s}", .{domain});
    if (self.path) |path| try writer.print("; Path={s}", .{path});
    if (self.expires) |exp| {
        try writer.writeAll("; Expires=");
        try exp.to_http_date().into_writer(writer);
    }
    if (self.max_age) |age| try writer.print("; Max-Age={d}", .{age});
    if (self.same_site) |same_site| try writer.print(
        "; SameSite={s}",
        .{same_site.to_string()},
    );
    if (self.secure) try writer.writeAll("; Secure");
    if (self.http_only) try writer.writeAll("; HttpOnly");

    return try aw.toOwnedSlice();
}

pub const Map = struct {
    allocator: mem.Allocator,
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: mem.Allocator) Map {
        return .{
            .allocator = allocator,
            .map = .init(allocator),
        };
    }

    pub fn deinit(self: *Map) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn clear(self: *Map) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.clearRetainingCapacity();
    }

    pub fn get(self: Map, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }

    pub fn count(self: Map) usize {
        return self.map.count();
    }

    pub fn iterator(self: *const Map) std.StringHashMap([]const u8).Iterator {
        return self.map.iterator();
    }

    // For parsing request cookies (simple key=value pairs)
    pub fn parse_from_header(self: *Map, cookie_header: []const u8) !void {
        self.clear();

        var pairs = mem.splitSequence(u8, cookie_header, "; ");
        while (pairs.next()) |pair| {
            var kv = mem.splitScalar(u8, pair, '=');
            const key = kv.next() orelse continue;
            const value = kv.rest();

            const key_dup = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_dup);
            const value_dup = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_dup);

            if (try self.map.fetchPut(key_dup, value_dup)) |existing| {
                self.allocator.free(existing.key);
                self.allocator.free(existing.value);
            }
        }
    }
};

test "Cookie: Header Parsing" {
    var cookie_map: Cookie.Map = .init(testing.allocator);
    defer cookie_map.deinit();

    try cookie_map.parse_from_header("sessionId=abc123; java=slop; foo=bar=baz");
    try testing.expectEqualStrings("abc123", cookie_map.get("sessionId").?);
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

    const formatted = try cookie.to_string_alloc(testing.allocator);
    defer testing.allocator.free(formatted);

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
