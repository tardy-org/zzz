
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
    const allocator = conn.runtime.allocator;
    ////var buffer: [65536]u8 = undefined;  //const buffer = try allocator.alloc(u8, 65536);  //defer allocator.free(buffer);
    
    const read_buffer_size = 4096; // 4kb = RAM page, so read by 4kb
    const read_buffer = try allocator.alloc(u8, read_buffer_size);
    defer allocator.free(read_buffer);
    
    var stash = std.ArrayList(u8).init(allocator);
    defer stash.deinit();
    
    var fragment = std.ArrayList(u8).init(allocator);
    defer fragment.deinit();
    
    while (true) {
        const n = conn.socket.recv(conn.runtime, read_buffer) catch |err| {
            if (err == error.Closed) {
                if (handler.on_disconnect) |on_disconnect| { try on_disconnect(conn); } //_ = on_disconnect(conn);
                return;
            }
            return err;
        };
        
        if (n == 0) {
          if (handler.on_disconnect) |on_disconnect| { try on_disconnect(conn); }
          return;
        }
        
        try stash.appendSlice(read_buffer[0..n]);
        
        var process_offset: usize = 0;
        const data = stash.items;
        
        // RFC 6455
        while (true) {
          if (process_offset + 2 > data.len) break; // minimal header = 2 bytes
          
          const start_idx = process_offset;
          const byte1 = data[start_idx];
          const byte2 = data[start_idx + 1];
          
          const fin = (byte1 & 0x80) != 0;
          const rsv1 = (byte1 & 0x40) != 0;
          const opcode = byte1 & 0x0F;
          const has_mask = (byte2 & 0x80) != 0;
          var payload_len = @as(usize, byte2 & 0x7F);
          
          var header_len: usize = 2;
          
          if (payload_len == 126) {
            if (start_idx + 4 > data.len) break; // waiting more bytes
            payload_len = @as(usize, data[start_idx + 2]) << 8 | @as(usize, data[start_idx + 3]);
            header_len += 2;
          
          } else if (payload_len == 127) {
            if (start_idx + 10 > data.len) break; // waiting more bytes
            
            payload_len = 
              @as(usize, data[start_idx+2]) << 56 |
              @as(usize, data[start_idx+3]) << 48 |
              @as(usize, data[start_idx+4]) << 40 |
              @as(usize, data[start_idx+5]) << 32 |
              @as(usize, data[start_idx+6]) << 24 |
              @as(usize, data[start_idx+7]) << 16 |
              @as(usize, data[start_idx+8]) << 8  |
              @as(usize, data[start_idx+9]);
            header_len += 8;
          }
          
          var mask: [4]u8 = undefined;
          if (has_mask) {
            if (start_idx + header_len + 4 > data.len) break;
            @memcpy(&mask, data[start_idx + header_len..][0..4]);
            header_len += 4;
          }
          
          const total_frame_len = header_len + payload_len;
          if (start_idx + total_frame_len > data.len) break; // is complete?
          
          const payload_start = start_idx + header_len; // must be complete
          const payload = data[payload_start .. payload_start + payload_len];
          
          if (has_mask) {
            var j: usize = 0;
            while (j < payload_len) : (j += 1) {
              payload[j] ^= mask[j % 4];
            }
          }
          
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
          
          process_offset += total_frame_len;
        }
        
        if (process_offset > 0) { // clean
          const remaining = data.len - process_offset;
          if (remaining == 0) { // clean buffer
            stash.clearRetainingCapacity();
            
            if (stash.capacity > 1024 * 1024) { // free RAM when buffer size more than 1mb
              stash.shrinkAndFree(0);
            }
          
          } else {
            std.mem.copyForwards(u8, stash.items[0..remaining], stash.items[process_offset..]);
            stash.shrinkRetainingCapacity(remaining);
          }
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

