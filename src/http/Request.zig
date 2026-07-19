pub const Request = @This();

allocator: mem.Allocator,
method: ?http.Method = null,
uri: ?[]const u8 = null,
version: ?std.http.Version = .@"HTTP/1.1",
headers: string_map.AnyCase,
cookies: Cookie.Map,
body: ?[]const u8 = null,

/// This is for constructing a Request.
pub fn init(allocator: mem.Allocator) Request {
    const headers: string_map.AnyCase = .init(allocator);
    const cookies: Cookie.Map = .init(allocator);

    return .{
        .allocator = allocator,
        .headers = headers,
        .cookies = cookies,
    };
}

pub fn deinit(self: *Request) void {
    self.cookies.deinit();
    self.headers.deinit();
}

pub fn clear(self: *Request) void {
    self.method = null;
    self.uri = null;
    self.body = null;
    self.cookies.clear();
    self.headers.clearRetainingCapacity();
}

const RequestParseOptions = struct {
    request_bytes_max: u32,
    request_uri_bytes_max: u32,
};

pub fn parse_headers(
    self: *Request,
    bytes: []const u8,
    options: RequestParseOptions,
) !void {
    self.clear();
    var total_size: u32 = 0;
    var lines = mem.tokenizeAny(u8, bytes, "\r\n");

    if (lines.peek() == null) {
        return http.Error.MalformedRequest;
    }

    var parsing_first_line = true;
    while (lines.next()) |line| {
        total_size += @intCast(line.len);

        if (total_size > options.request_bytes_max) {
            return http.Error.ContentTooLarge;
        }

        if (parsing_first_line) {
            var chunks = mem.tokenizeScalar(u8, line, ' ');

            const method_string = chunks.next() orelse
                return http.Error.MalformedRequest;
            const method = http.Method.parse(method_string) catch {
                log.warn("invalid method: {s}", .{method_string});
                return http.Error.InvalidMethod;
            };

            const uri_string = chunks.next() orelse
                return http.Error.MalformedRequest;
            if (uri_string.len >= options.request_uri_bytes_max)
                return http.Error.URITooLong;
            if (uri_string[0] != '/') return http.Error.MalformedRequest;

            const version_string = chunks.next() orelse
                return http.Error.MalformedRequest;
            if (!mem.eql(u8, version_string, "HTTP/1.1"))
                return http.Error.HTTPVersionNotSupported;
            self.set(.{ .method = method, .uri = uri_string });

            // There shouldn't be anything else.
            if (chunks.next() != null) return http.Error.MalformedRequest;
            parsing_first_line = false;
        } else {
            var header_iter = mem.tokenizeScalar(u8, line, ':');
            const key = header_iter.next() orelse
                return http.Error.MalformedRequest;
            const value = mem.trimStart(
                u8,
                header_iter.rest(),
                &.{' '},
            );
            if (value.len == 0) return http.Error.MalformedRequest;
            try self.headers.put(key, value);
        }
    }

    if (self.headers.get("Cookie")) |cookies|
        try self.cookies.parse_from_header(cookies);
}

pub const RequestSetOptions = struct {
    method: ?http.Method = null,
    uri: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

pub fn set(self: *Request, options: RequestSetOptions) void {
    if (options.method) |method| {
        self.method = method;
    }

    if (options.uri) |uri| {
        self.uri = uri;
    }

    if (options.body) |body| {
        self.body = body;
    }
}

/// Should this specific Request expect to capture a body.
pub fn expect_body(self: Request) bool {
    return switch (self.method orelse return false) {
        .POST, .PUT, .PATCH => true,
        .GET, .HEAD, .DELETE, .CONNECT, .OPTIONS, .TRACE => false,
    };
}

test "Parse Request" {
    const request_text =
        \\GET / HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    var request = Request.init(testing.allocator);
    defer request.deinit();

    try request.parse_headers(request_text[0..], .{
        .request_bytes_max = 1024,
        .request_uri_bytes_max = 256,
    });

    try testing.expectEqual(.GET, request.method);
    try testing.expectEqualStrings("/", request.uri.?);
    try testing.expectEqual(.@"HTTP/1.1", request.version);

    try testing.expectEqualStrings("localhost:9862", request.headers.get("Host").?);
    try testing.expectEqualStrings("keep-alive", request.headers.get("Connection").?);
    try testing.expectEqualStrings("text/html", request.headers.get("Accept").?);
}

test "Expect ContentTooLong Error" {
    const request_text_format =
        \\GET {s} HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    const large_content: [4096]u8 = @splat('a');
    const request_text = std.fmt.comptimePrint(request_text_format, .{large_content});
    var request: Request = .init(testing.allocator);
    defer request.deinit();

    const err = request.parse_headers(request_text[0..], .{
        .request_bytes_max = 128,
        .request_uri_bytes_max = 64,
    });
    try testing.expectError(http.Error.ContentTooLarge, err);
}

test "Expect URITooLong Error" {
    const request_text_format =
        \\GET {s} HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    const large_content: [4096]u8 = @splat('a');
    const request_text = std.fmt.comptimePrint(
        request_text_format,
        .{large_content[0..]},
    );
    var request: Request = .init(testing.allocator);
    defer request.deinit();

    const err = request.parse_headers(request_text[0..], .{
        .request_bytes_max = 1024 * 1024,
        .request_uri_bytes_max = 2048,
    });
    try testing.expectError(http.Error.URITooLong, err);
}

test "Expect Malformed when URI missing /" {
    const request_text_format =
        \\GET {s} HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;
    const content: [256]u8 = @splat('a');
    const request_text = std.fmt.comptimePrint(
        request_text_format,
        .{content[0..]},
    );
    var request: Request = .init(testing.allocator);
    defer request.deinit();

    const err = request.parse_headers(request_text[0..], .{
        .request_bytes_max = 1024,
        .request_uri_bytes_max = 512,
    });
    try testing.expectError(
        http.Error.MalformedRequest,
        err,
    );
}

test "Expect Incorrect HTTP Version" {
    const request_text =
        \\GET / HTTP/1.4
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    var request: Request = .init(testing.allocator);
    defer request.deinit();

    const err = request.parse_headers(request_text[0..], .{
        .request_bytes_max = 1024,
        .request_uri_bytes_max = 512,
    });
    try testing.expectError(
        http.Error.HTTPVersionNotSupported,
        err,
    );
}

test "Malformed string_map.AnyCase" {
    const request_text =
        \\GET / HTTP/1.1
        \\Host: localhost:9862
        \\Connection:
        \\Accept: text/html
    ;

    var request: Request = .init(testing.allocator);
    defer request.deinit();

    const err = request.parse_headers(request_text[0..], .{
        .request_bytes_max = 1024,
        .request_uri_bytes_max = 512,
    });
    try testing.expectError(http.Error.MalformedRequest, err);
}

const log = std.log.scoped(.@"zzz/http/request");

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;

const zzz = @import("../root.zig");
const string_map = zzz.core.string_map;
const http = zzz.http;
const Cookie = @import("Cookie.zig");
