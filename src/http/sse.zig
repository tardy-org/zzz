const std = @import("std");
const Writer = std.Io.Writer;

const Runtime = @import("tardy").Runtime;
const secsock = @import("secsock");
const SecureSocket = secsock.SecureSocket;

const Pseudoslice = @import("../core/pseudoslice.zig").Pseudoslice;
const Context = @import("context.zig").Context;
const Mime = @import("mime.zig").Mime;
const Provision = @import("server.zig").Provision;

const log = std.log.scoped(.@"zzz/http/sse");

const SSEMessage = struct {
    id: ?[]const u8 = null,
    event: ?[]const u8 = null,
    data: ?[]const u8 = null,
    retry: ?u64 = null,
};

pub const SSE = struct {
    socket: SecureSocket,
    writer: Writer.Allocating,
    runtime: *Runtime,

    pub fn init(ctx: *const Context) !SSE {
        const response = ctx.response;
        response.status = .OK;
        response.mime = .{
            .content_type = .{ .single = "text/event-stream" },
            .extension = .{ .single = "" },
            .description = "SSE",
        };

        var writer: Writer.Allocating = .init(ctx.allocator);
        errdefer writer.deinit();

        try ctx.response.headers_into_writer(ctx.header_writer, null);
        const headers = ctx.header_writer.buffered();

        const sent = try ctx.socket.send_all(ctx.runtime, headers);
        if (sent != headers.len) return error.Closed;

        return .{
            .socket = ctx.socket,
            .writer = writer,
            .runtime = ctx.runtime,
        };
    }

    pub fn send(self: *SSE, message: SSEMessage) !void {
        var aw = &self.writer;
        defer aw.clearRetainingCapacity(); // reuse the writer
        const writer = &aw.writer;

        if (message.id) |id| try writer.print("id: {s}\n", .{id});
        if (message.event) |event| try writer.print("event: {s}\n", .{event});
        if (message.data) |data| {
            var iter = std.mem.splitScalar(u8, data, '\n');
            while (iter.next()) |line| try writer.print("data: {s}\n", .{line});
        }
        if (message.retry) |retry| try writer.print("retry: {d}\n", .{retry});
        try writer.writeByte('\n');

        const written = aw.written();
        const sent = try self.socket.send_all(self.runtime, written);
        if (sent != written.len) return error.Closed;
    }
};
