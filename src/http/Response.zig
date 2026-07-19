pub const Response = @This();

status: ?Status = null,
mime: ?Mime = null,
body: ?[]const u8 = null,
headers: string_map.AnyCase,

pub const Fields = struct {
    status: Status,
    mime: Mime,
    body: []const u8 = "",
    headers: []const [2][]const u8 = &.{},
};

pub fn init(allocator: std.mem.Allocator) Response {
    const headers: string_map.AnyCase = .init(allocator);
    return .{ .headers = headers };
}

pub fn deinit(self: *Response) void {
    self.headers.deinit();
}

pub fn apply(self: *Response, into: Fields) !http.Respond {
    self.status = into.status;
    self.mime = into.mime;
    self.body = into.body;
    for (into.headers) |pair|
        try self.headers.put(pair[0], pair[1]);
    return .standard;
}

pub fn clear(self: *Response) void {
    self.status = null;
    self.mime = null;
    self.body = null;
    self.headers.clearRetainingCapacity();
}

pub fn headers_into_writer(
    self: *Response,
    writer: *Io.Writer,
    content_length: ?usize,
) !void {
    // Status Line
    const status = self.status.?;
    try writer.print(
        "HTTP/1.1 {d} {t}\r\n",
        .{ status, status },
    );

    // Headers
    try writer.writeAll("Server: zzz\r\nConnection: keep-alive\r\n");
    var iter = self.headers.iterator();
    while (iter.next()) |entry| try writer.print(
        "{s}: {s}\r\n",
        .{ entry.key_ptr.*, entry.value_ptr.* },
    );

    // Content-Type
    const mime = self.mime.?;
    const content_type = switch (mime.content_type) {
        .single => |inner| inner,
        .multiple => |content_types| content_types[0],
    };
    try writer.print("Content-Type: {s}\r\n", .{content_type});

    // Content-Length
    if (content_length) |length|
        try writer.print("Content-Length: {d}\r\n", .{length});

    try writer.writeAll("\r\n");
}

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

const zzz = @import("../root.zig");
const tardy = zzz.tardy;
const http = zzz.http;
const string_map = zzz.core.string_map;
const Date = @import("Date.zig");
const Mime = @import("Mime.zig");
const Status = @import("status.zig").Status;
