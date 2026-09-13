pub const Request = @This();

version: http.Version = .@"HTTP/1.1",
method: ?http.Method = null,
uri: ?[]const u8 = null,
headers: http.Headers,
cookies: Cookie.Map,
body: ?[]const u8 = null,

/// Construct a new Request.
pub fn init(gpa: mem.Allocator, header_fields_count_max: u32) OoM!Request {
    var new: Request = .{
        .headers = .empty,
        .cookies = .empty,
    };
    try new.headers.ensureTotalCapacity(
        gpa,
        header_fields_count_max,
    );
    return new;
}

pub fn deinit(request: *Request, gpa: mem.Allocator) void {
    request.cookies.deinit(gpa);

    // Request `headers` key <-> value pair are externally managed
    // as they come from the client's Request
    request.headers.deinit(gpa);
}

pub fn clear(request: *Request, gpa: mem.Allocator) void {
    request.method = null;
    request.uri = null;
    request.body = null;
    request.cookies.clear(gpa);
    request.headers.clearRetainingCapacity();
}

pub fn parse(
    request: *Request,
    gpa: mem.Allocator,
    headers: []const u8,
    options: Options,
) (OoM || http.Error)!void {
    request.headers.clearRetainingCapacity();

    var lines = mem.tokenizeAny(
        u8,
        headers,
        "\r\n",
    );

    if (lines.peek() == null) return error.MalformedRequest;

    const request_line = lines.next().?;

    var chunks = mem.tokenizeScalar(
        u8,
        request_line,
        ' ',
    );

    const method_string = chunks.next() orelse
        return error.MalformedRequest;

    const method: http.Method = try .parse(method_string);
    request.method = method;

    const uri = chunks.next() orelse
        return error.MalformedRequest;

    if (uri.len > options.request_uri_bytes_max.Usize())
        return error.URITooLong;

    if (uri[0] != '/' and mem.find(u8, uri[0..4], "http") == null)
        return error.MalformedRequest;
    request.uri = uri;

    const version_string = chunks.next() orelse
        return error.MalformedRequest;

    const version = meta.stringToEnum(
        http.Version,
        version_string,
    ) orelse return error.UnSupportedHTTPVersion;
    request.version = version;

    // There shouldn't be anything else.
    if (chunks.next() != null) return error.MalformedRequest;

    var request_size_total: usize = request_line.len;
    while (lines.next()) |header| : ({
        request_size_total += header.len;
    }) {
        if (request_size_total > options.request_bytes_max.Usize())
            return error.ContentTooLarge;

        // https://datatracker.ietf.org/doc/html/rfc9112#name-field-line-parsing
        var header_iter = mem.tokenizeScalar(
            u8,
            header,
            ':',
        );
        const key = header_iter.next() orelse
            return error.MalformedRequest;

        if (key[key.len - 1] == ' ') return error.MalformedRequest;

        const value = mem.trimStart(
            u8,
            header_iter.rest(),
            " ",
        );

        if (value.len == 0) return error.MalformedRequest;

        // FIXME(bernardassan): when a key is repeated with values
        // https://datatracker.ietf.org/doc/html/rfc9110#name-field-lines-and-combined-fi
        request.headers.putAssumeCapacityNoClobber(
            key,
            value,
        );
    }

    if (request.headers.get("Cookie")) |cookies|
        try request.cookies.parse(gpa, cookies);
}

/// Should this specific Request expect to capture a body.
pub fn expect_body(request: *const Request) bool {
    return switch (request.method orelse return false) {
        .POST, .PUT, .PATCH => true,
        .GET, .HEAD, .DELETE, .CONNECT, .OPTIONS, .TRACE => false,
    };
}

test "Parse Request" {
    const gpa = testing.allocator;
    const request_header =
        \\GET / HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    var request: Request = try .init(gpa, 4);
    defer request.deinit(gpa);

    try request.parse(gpa, request_header[0..], .{
        .request_bytes_max = .Bytes(64),
        .request_uri_bytes_max = .Bytes(1),
    });

    try testing.expectEqual(.GET, request.method);
    try testing.expectEqualStrings("/", request.uri.?);
    try testing.expectEqual(.@"HTTP/1.1", request.version);

    try testing.expectEqualStrings(
        "localhost:9862",
        request.headers.get("Host").?,
    );
    try testing.expectEqualStrings(
        "keep-alive",
        request.headers.get("Connection").?,
    );
    try testing.expectEqualStrings(
        "text/html",
        request.headers.get("Accept").?,
    );
}

test "Expect ContentTooLong Error" {
    const request_text_format =
        \\GET /{s} HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    const uri: [33]u8 = @splat('a');
    const request_text = fmt.comptimePrint(
        request_text_format,
        .{uri},
    );
    const gpa = testing.allocator;
    var request: Request = try .init(gpa, 4);
    defer request.deinit(gpa);

    const err = request.parse(
        gpa,
        request_text[0..],
        .{
            .request_bytes_max = .Bytes(42),
            .request_uri_bytes_max = .Bytes(34), // + /
        },
    );
    try testing.expectError(
        error.ContentTooLarge,
        err,
    );
}

test "Expect URITooLong Error" {
    const request_text_format =
        \\GET {s} HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    const uri: [33]u8 = @splat('a');
    const request_text = fmt.comptimePrint(
        request_text_format,
        .{uri[0..]},
    );
    const gpa = testing.allocator;
    var request: Request = try .init(gpa, 4);
    defer request.deinit(gpa);

    const err = request.parse(
        gpa,
        request_text[0..],
        .{
            .request_bytes_max = .Bytes(64),
            .request_uri_bytes_max = .Bytes(32),
        },
    );
    try testing.expectError(error.URITooLong, err);
}

test "Expect Malformed when URI missing /" {
    const request_text_format =
        \\GET {s} HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;
    const uri: [32]u8 = @splat('a');
    const request_text = fmt.comptimePrint(
        request_text_format,
        .{uri[0..]},
    );
    const gpa = testing.allocator;
    var request: Request = try .init(gpa, 4);
    defer request.deinit(gpa);

    const err = request.parse(
        gpa,
        request_text[0..],
        .{
            .request_bytes_max = .Bytes(64),
            .request_uri_bytes_max = .Bytes(33),
        },
    );
    try testing.expectError(
        error.MalformedRequest,
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

    const gpa = testing.allocator;
    var request: Request = try .init(gpa, 4);
    defer request.deinit(gpa);

    const err = request.parse(
        gpa,
        request_text[0..],
        .{
            .request_bytes_max = .Bytes(64),
            .request_uri_bytes_max = .Bytes(1),
        },
    );
    try testing.expectError(
        error.UnSupportedHTTPVersion,
        err,
    );
}

test "Malformed Request" {
    const request_text =
        \\GET / HTTP/1.1
        \\Host: localhost:9862
        \\Connection:
        \\Accept: text/html
    ;

    const gpa = testing.allocator;
    var request: Request = try .init(gpa, 4);
    defer request.deinit(gpa);

    const err = request.parse(
        gpa,
        request_text[0..],
        .{
            .request_bytes_max = .Bytes(64),
            .request_uri_bytes_max = .Bytes(1),
        },
    );
    try testing.expectError(
        error.MalformedRequest,
        err,
    );
}

const Options = struct {
    request_bytes_max: core.Size,
    request_uri_bytes_max: core.Size,
};

const log = std.log.scoped(.@"zzz/http/request");

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const meta = std.meta;
const testing = std.testing;
const OoM = mem.Allocator.Error;

const zzz = @import("zzz");
const core = zzz.core;
const http = zzz.http;
const Cookie = @import("Cookie.zig");
