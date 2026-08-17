pub const Response = @This();

status: ?Status = null,
mime: ?Mime = null,
body: ?[]const u8 = null,
headers: string_map.AnyCase,

// TODO: there shouldn't be a need for this, we should be able to use
// reponse everywhere or update it to the needed use cases
pub const Fields = struct {
    status: Status,
    mime: Mime,
    body: []const u8 = "",
    headers: []const [2][]const u8 = &.{},
};

pub const empty: Response = .{
    .headers = .empty,
};

pub fn deinit(response: *Response, gpa: mem.Allocator) void {
    response.headers.deinit(gpa);
}

pub fn apply(response: *Response, into: Fields) !http.Respond {
    const ctx: *http.Context = @fieldParentPtr(
        "response",
        response,
    );
    response.status = into.status;
    response.mime = into.mime;
    response.body = into.body;
    for (into.headers) |pair|
        try response.headers.put(ctx.arena, pair[0], pair[1]);
    return .standard;
}

pub fn clear(response: *Response) void {
    response.status = null;
    response.mime = null;
    response.body = null;
    response.headers.clearRetainingCapacity();
}

pub fn headers_into_writer(
    response: *Response,
    writer: *Io.Writer,
    content_length: ?usize,
) !void {
    // Status Line
    const status = response.status.?;
    try writer.print(
        "HTTP/1.1 {d} {t}\r\n",
        .{ status, status },
    );

    // Headers
    try writer.writeAll("Server: Zzz\r\nConnection: keep-alive\r\n");
    var iter = response.headers.iterator();
    while (iter.next()) |entry| try writer.print(
        "{s}: {s}\r\n",
        .{ entry.key_ptr.*, entry.value_ptr.* },
    );

    // Content-Type
    const mime = response.mime.?;
    const content_type = switch (mime.content_type) {
        .single => |single| single,
        .multiple => |content_types| content_types[0],
    };
    try writer.print("Content-Type: {s}\r\n", .{content_type});

    // Content-Length
    if (content_length) |length|
        try writer.print("Content-Length: {d}\r\n", .{length});

    try writer.writeAll("\r\n");
}

const std = @import("std");
const mem = std.mem;
const Io = std.Io;

const zzz = @import("../root.zig");
const tardy = zzz.tardy;
const http = zzz.http;
const string_map = zzz.core.string_map;
const Date = @import("Date.zig");
const Mime = @import("Mime.zig");
const Status = @import("status.zig").Status;
