
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
    var buffer: [65536]u8 = undefined;
    while (true) {
        const n = conn.socket.recv(conn.runtime, &buffer) catch |err| {
            if (err == error.Closed) {
                if (handler.on_disconnect) |on_disconnect| {
                    _ = on_disconnect(conn);
                }
                return;
            }
            return err;
        };

        // RFC 6455
        var i: usize = 0;
        while (i < n) {
            const op = buffer[i];
            const fin = (op & 0x80) != 0;
            const opcode = op & 0x0F;
            i += 1;

            if (i >= n) return error.InvalidWebSocketFrame;

            const mask_flag = (buffer[i] & 0x80) != 0;
            const payload_len_raw = buffer[i] & 0x7F;
            i += 1;

            if (i >= n) return error.InvalidWebSocketFrame;

            var payload_len: usize = payload_len_raw;
            var extra: usize = 0;
            if (payload_len_raw == 126) {
                if (i + 2 > n) return error.InvalidWebSocketFrame;
                payload_len = @as(usize, @bitCast(std.mem.readIntBig(u16, buffer[i..])));
                extra = 2;
            } else if (payload_len_raw == 127) {
                if (i + 8 > n) return error.InvalidWebSocketFrame;
                payload_len = @as(usize, @bitCast(std.mem.readIntBig(u64, buffer[i..])));
                extra = 8;
            }

            i += extra;
            if (mask_flag) {
                if (i + 4 > n) return error.InvalidWebSocketFrame;
                const mask = buffer[i..][0..4].*;
                i += 4;
                if (i + payload_len > n) return error.InvalidWebSocketFrame;
                
                //for (0..payload_len) |j| {
                //    buffer[i + j] ^= mask[j % 4];
                //} // use next vector optimising instead this
                
                var j: usize = 0;
                const vec_len = std.simd.suggestVectorLength(u8) orelse 16;
                const Vector = @Vector(vec_len, u8);
                
                var mask_arr: [vec_len]u8 = undefined;
                for (0..vec_len) |k| mask_arr[k] = mask[k % 4];
                const mask_vec: Vector = mask_arr;
                
                while (j + vec_len <= payload_len) {
                  const chunk: Vector = buffer[i+j..][0..vec_len].*;
                  const res = chunk ^ mask_vec;
                  buffer[i+j..][0..vec_len].* = res;
                  j += vec_len;
                }
                
                while (j < payload_len) : (j += 1) {
                  buffer[i + j] ^= mask[j % 4];
                }
                
                
            }

            if (i + payload_len > n) return error.InvalidWebSocketFrame;

            switch (opcode) {
                0x1 => { // Text
                    if (fin and handler.on_message) |on_msg| {
                        try on_msg(conn, buffer[i .. i + payload_len]);
                    }
                },
                0x8 => { // Close
                    conn.close();
                    if (handler.on_disconnect) |on_disconnect| {
                        _ = on_disconnect(conn);
                    }
                    return;
                },
                0x9 => { // Ping - reply Pong
                    const pong = ([2]u8{ 0x8A, @intCast(@min(payload_len, 125)) })[0..];
                    _ = try conn.socket.send_all(conn.runtime, pong);
                    if (payload_len <= 125) {
                        _ = try conn.socket.send_all(conn.runtime, buffer[i .. i + payload_len]);
                    }
                },
                else => {
                    // ignore other opcode (binary, pong etc)
                },
            }

            i += payload_len;
        }
    }
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

