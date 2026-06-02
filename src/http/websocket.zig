
const std = @import("std");

const zzz = @import("../lib.zig");

const websocket = zzz.websocket;
const SecureSocket = zzz.secsock.SecureSocket;
const Runtime = zzz.tardy.Runtime;

const Context = @import("context.zig").Context;


pub const WebSocketHandler = struct {
    on_connect: ?*const fn (Conn) anyerror!void = null,
    on_message: ?*const fn (Conn, []const u8) anyerror!void = null,
    on_disconnect: ?*const fn (Conn) anyerror!void = null,
    user_data: ?*anyopaque = null,
};

pub const Conn = struct {
    socket: *const SecureSocket,
    runtime: *Runtime,
    user_data: ?*anyopaque,

    pub fn send(self: Conn, data: []const u8) !void {
        const frame = websocket.frameText(data);
        _ = try self.socket.send_all(self.runtime, frame);
    }

    pub fn close(self: Conn) void {
        self.socket.close_blocking();
    }
};

pub fn upgrade_to_websocket(
    ctx: *const Context,
    handler: WebSocketHandler,
) !bool {
    const req = ctx.request;
    const res = ctx.response;

    // handshake
    if (!std.mem.eql(u8, req.headers.get("Connection") orelse "", "Upgrade"))
        return false;
    if (!std.mem.eql(u8, req.headers.get("Upgrade") orelse "", "websocket"))
        return false;
    if (!std.mem.eql(u8, req.headers.get("Sec-WebSocket-Version") orelse "", "13"))
        return false;

    const key = req.headers.get("Sec-WebSocket-Key") orelse return false;

    // Sec-WebSocket-Accept
    const accept = try compute_accept(ctx.allocator, key);

    // 101 Switching Protocols
    res.clear();
    try res.headers.put("Upgrade", "websocket");
    try res.headers.put("Connection", "Upgrade");
    try res.headers.put("Sec-WebSocket-Accept", accept);
    res.status = .@"Switching Protocols";

    try res.headers_into_writer(ctx.header_buffer.writer(), 0);
    _ = try ctx.socket.send_all(ctx.runtime, ctx.header_buffer.items);

    // WebSocket Conn
    const conn = Conn{
        .socket = &ctx.socket,
        .runtime = ctx.runtime,
        .user_data = handler.user_data,
    };

    // on_connect
    if (handler.on_connect) |on_connect| {
        try on_connect(conn);
    }

    // process
    try ctx.runtime.spawn(.{ conn, handler }, message_loop, 64 * 1024);
    return true;
}

// inner loop
fn message_loop(conn: Conn, handler: WebSocketHandler) !void {
  try websocket.runLoop(
    .{
      .socket = conn.socket,
      .runtime = conn.runtime,
      .user_data = conn.user_data,
    },
    .{
      .on_connect = handler.on_connect,
      .on_message = handler.on_message,
      .on_disconnect = handler.on_disconnect,
    },
    conn.runtime.allocator,
  );
}

// Sec-WebSocket-Accept
fn compute_accept(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hasher = std.crypto.hash.sha1.Sha1.init();
    hasher.update(key);
    hasher.update(magic);
    const hash = hasher.final();
    return try std.base64.encode(allocator, &hash);
}

