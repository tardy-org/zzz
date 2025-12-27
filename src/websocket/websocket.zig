
// websocket - RFC 6455 + RFC 7692 (permessage-deflate) // todo fix last one

const std = @import("std");

const Allocator = std.mem.Allocator;

const SecureSocket = @import("secsock").SecureSocket;
const Runtime = @import("tardy").Runtime;

const compress = std.compress;


pub const Conn = struct {
    socket: *const SecureSocket,
    runtime: *Runtime,
    user_data: ?*anyopaque = null,
    //allocator: Allocator, // maybe todo - and pass with on_upgrade
    //compression: bool,
    
    pub fn send(self: Conn, data: []const u8) !void {
        var buf = std.ArrayList(u8).init(self.runtime.allocator);
        defer buf.deinit();
        
        //try writeFrameHeader(buf.writer(), .text, data.len, true);
        try writeFrameHeader(buf.writer(), .text, data.len, false);
        try buf.appendSlice(data);
        _ = try self.socket.send_all(self.runtime, buf.items);
    }
    
    pub fn sendBinary(self: Conn, binary_data: []const u8) !void {
        var buf = std.ArrayList(u8).init(self.runtime.allocator);
        defer buf.deinit();
        
        try writeFrameHeader(buf.writer(), .binary, binary_data.len, false);
        try buf.appendSlice(binary_data);
        _ = try self.socket.send_all(self.runtime, buf.items);
        
    }
    
    pub fn close(self: Conn, code: u16, reason: []const u8) !void {
      if (reason.len > 123) return error.ReasonTooLong;
      
      var buf = std.ArrayList(u8).init(self.runtime.allocator);
      defer buf.deinit();
      
      const payload_len = 2 + reason.len;
      try writeFrameHeader(buf.writer(), .close, payload_len, false); // close header
      
      try buf.writer().writeInt(u16, code, .big); // big-endian
      
      if (reason.len > 0) {
        try buf.appendSlice(reason);
      }
      
      _ = try self.socket.send_all(self.runtime, buf.items);
    }
    
};


pub const Handler = struct {
    on_connect: ?*const fn (Conn) anyerror!void = null,
    on_message: ?*const fn (Conn, []const u8) anyerror!void = null,
    on_binary: ?*const fn (Conn, []const u8) anyerror!void = null,
    on_close: ?*const fn (Conn, u16, []const u8) anyerror!void = null,
    on_disconnect: ?*const fn (Conn) anyerror!void = null,
};

pub const HandshakeResult = struct {
    conn: Conn,
    //compression: bool,
};

pub fn upgrade(
    socket: *const SecureSocket,
    runtime: *Runtime,
    allocator: Allocator,
    sec_websocket_key: []const u8,
    sec_websocket_extensions: ?[]const u8,
    response_writer: anytype,
) !HandshakeResult {
    _ = sec_websocket_extensions;
    //var compression = false;
    //if (sec_websocket_extensions) |ext| {
    //    if (std.mem.indexOf(u8, ext, "permessage-deflate") != null) {
    //        const has_client_no_ctx = std.mem.indexOf(u8, ext, "client_no_context_takeover") != null;
    //        const has_server_no_ctx = std.mem.indexOf(u8, ext, "server_no_context_takeover") != null;
    //        if (has_client_no_ctx and has_server_no_ctx) {
    //            compression = true;
    //        }
    //    }
    //}
    
    const accept = try computeAccept(allocator, sec_websocket_key);
    try response_writer.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    try response_writer.writeAll("Upgrade: websocket\r\n");
    try response_writer.writeAll("Connection: Upgrade\r\n");
    try response_writer.writeAll("Sec-WebSocket-Accept: ");
    try response_writer.writeAll(accept);
    try response_writer.writeAll("\r\n");
    //if (compression) {
    //    try response_writer.writeAll("Sec-WebSocket-Extensions: permessage-deflate; server_no_context_takeover; client_no_context_takeover\r\n");
    //}
    try response_writer.writeAll("\r\n");

    return .{
        .conn = Conn{
            .socket = socket,
            .runtime = runtime,
            .user_data = null,
            //.compression = compression,
        },
        //.compression = compression,
    };
}

pub fn runLoop(conn: Conn, handler: Handler, allocator: Allocator) !void {
    //const buffer = try allocator.alloc(u8, 65536);
    //defer allocator.free(buffer);
    
    const read_buffer_size = 4096; // buffer for read from socket, 4 kb for one read syscall
    const read_buffer = try allocator.alloc(u8, read_buffer_size);
    defer allocator.free(read_buffer);
    
    var stash = std.ArrayList(u8).init(allocator); // buffer for incompleted frames between recv calls
    defer stash.deinit();
    
    var fragment = std.ArrayList(u8).init(allocator); // for fragmented ws msg - Opcode 0x0
    defer fragment.deinit();
    
    var is_text: ?bool = null;
    
    while (true) {
        const n = conn.socket.recv(conn.runtime, read_buffer) catch |err| {
            if (err == error.Closed) {
                if (handler.on_disconnect) |on_disc| try on_disc(conn);
                return;
            }
            return err;
        };
        
        if (n == 0) { // if read 0 bytes - but no error.Closed- this can be disconnect too
           if (handler.on_disconnect) |on_disc| try on_disc(conn);
           return;
        }
        
        try stash.appendSlice(read_buffer[0..n]); // save readed
        
        var process_offset: usize = 0;
        const data = stash.items;
        
        
        while (true) { // do process collected
          if (process_offset + 2 > data.len) break; // must be at least 2 bytes - minimal header
          
          const start_idx = process_offset;
          const byte1 = data[start_idx];
          const byte2 = data[start_idx + 1];
          
          const fin = (byte1 & 0x80) != 0;
          const rsv1 = (byte1 & 0x40) != 0;
          const opcode = byte1 & 0x0F;
          const has_mask = (byte2 & 0x80) != 0;
          var payload_len = @as(usize, byte2 & 0x7F);
          
          var header_len: usize = 2;
          
          if (payload_len == 126) { // check header length
            if (start_idx + 4 > data.len) break; // lets wait for more data
            //payload_len = std.mem.readInt(u16, data[start_idx+2..][0..2], .big);
            payload_len = @as(usize, data[start_idx+2]) << 8 | @as(usize, data[start_idx+3]);
            header_len += 2;
          } else if (payload_len == 127) {
            if (start_idx + 10 > data.len) break; // lets wait for more data
            //payload_len = std.mem.readInt(u64, data[start_idx+2..][0..8], .big);
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
            if (start_idx + header_len + 4 > data.len) break; // lets wait for mask
            @memcpy(&mask, data[start_idx + header_len..][0..4]);
            header_len += 4;
          }
          
          const total_frame_len = header_len + payload_len; // check we have complete message' body
          if (start_idx + total_frame_len > data.len) break; // lets wait for rest message' body
          // here we got complete frame
          
          const payload_start = start_idx + header_len;
          const payload = data[payload_start .. payload_start + payload_len];
          
          if (has_mask) { // unmask
            var j: usize = 0;
            while (j < payload_len) : (j += 1) {
              payload[j] ^= mask[j % 4];
            }
          }
          
          // Compression (permessage-deflate) // todo
          if (rsv1) return error.CompressionNotNegotiated;
          //var decompressed: ?[]u8 = null;
          //if (rsv1) {
          //    if (!conn.compression) return error.CompressionNotNegotiated;
          //    const inflated_len = payload.len + 4;
          //    const inflated = try allocator.alloc(u8, inflated_len);
          //    errdefer allocator.free(inflated);
          //    @memcpy(inflated[0..payload.len], payload);
          //    inflated[payload.len + 0] = 0x00;
          //    inflated[payload.len + 1] = 0x00;
          //    inflated[payload.len + 2] = 0xFF;
          //    inflated[payload.len + 3] = 0xFF;
          //    const stream = std.io.fixedBufferStream(inflated);
          //    var inflater = compress.flate.InflateStream.init(stream.reader(), .{});
          //    defer inflater.deinit();
          //    var out = std.ArrayList(u8).init(allocator);
          //    errdefer out.deinit();
          //    try inflater.reader().readAllArrayList(&out, 1024 * 1024);
          //    allocator.free(inflated);
          //    decompressed = try out.toOwnedSlice();
          //    payload = decompressed.?;
          //}
          
          switch (opcode) {
            0x1 => { // Text
              if (is_text != null) return error.InvalidWebSocketFrame;
              is_text = true;
              
              if (fin) {
                if (handler.on_message) |on_msg| try on_msg(conn, payload);
                is_text = null; // because got complete message
                //if (decompressed) |d| allocator.free(d);
              } else {
                try fragment.appendSlice(payload);
                //if (decompressed) |d| allocator.free(d);
              }
            },
            
            0x2 => { // Binary
              if (is_text != null) return error.InvalidWebSocketFrame;
              is_text = false;
              
              if (fin) {
                if (handler.on_binary) |on_bin| try on_bin(conn, payload);
                is_text = null;
                //if (decompressed) |d| allocator.free(d);
              } else {
                try fragment.appendSlice(payload);
                //if (decompressed) |d| allocator.free(d);
              }
            },
            
            0x0 => { // Continuation
              if (is_text == null) return error.InvalidWebSocketFrame; // we got message' second part but we do not know first part - was no start frame
              
              try fragment.appendSlice(payload);
              
              if (fin) {
                const full = fragment.items;
                if (is_text.?) { // not null here
                  if (handler.on_message) |f| try f(conn, full);
                } else {
                  if (handler.on_binary) |f| try f(conn, full);
                }
                is_text = null;
                fragment.clearRetainingCapacity();
              }
              //if (decompressed) |d| allocator.free(d);
            },
            
            0x8 => { // Close
              var code: u16 = 1000; // Normal closure code by default
              var reason_slice: []const u8 = "";
              
              if (payload.len >= 2) {
                code = std.mem.readInt(u16, payload[0..2], .big);
                
                if (payload.len > 2) reason_slice = payload[2..];
              }
                // if (payload.len > 2) {
                  //reason_slice = payload[2..];
                  //if (!std.unicode.utf8ValidateSlice(reason_slice)) {
                    ////conn.socket.socket.close_blocking(); // that makes tardy
                    ////if (decompressed) |d| allocator.free(d);
                    //if (handler.on_disconnect) |on_disc| try on_disc(conn);
                    //return;
                  //}
                //}
              
              conn.close(code, "") catch {}; // just exit
              
              if (handler.on_close) |on_close| try on_close(conn, code, reason_slice);
              if (handler.on_disconnect) |on_disc| try on_disc(conn);
              //if (decompressed) |d| allocator.free(d);
              return;
            },
            
            0x9 => { // Ping
              const pong_payload = payload;
              
              var pong_buf = std.ArrayList(u8).init(allocator);
              defer pong_buf.deinit();
              
              try writeFrameHeader(pong_buf.writer(), .pong, pong_payload.len, false);
              try pong_buf.appendSlice(pong_payload);
              
              _ = try conn.socket.send_all(conn.runtime, pong_buf.items);
              //if (decompressed) |d| allocator.free(d);
            },
            
            0xA => { // Pong - ignore
              //if (decompressed) |d| allocator.free(d);
            },
            
            else => {
              //if (decompressed) |d| allocator.free(d);
              return error.UnsupportedOpcode;
            },
          }
          
          process_offset += total_frame_len; // shift offset
        } // while ends - processed collected
        
        if (process_offset > 0) { // clean frame buffer // maybe todo RingBuffer
          const remaining = data.len - process_offset;
          if (remaining == 0) {
            stash.clearRetainingCapacity();
          } else {
            std.mem.copyForwards(u8, stash.items[0..remaining], stash.items[process_offset..]); // mv tail to begin
            stash.shrinkRetainingCapacity(remaining);
          }
        }
    
    }
}


// helpers

fn computeAccept(allocator: Allocator, key: []const u8) ![]const u8 {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(magic);
    var hash: [20]u8 = undefined;
    hasher.final(&hash);
    var buf: [28]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&buf, &hash);
    return try allocator.dupe(u8, encoded);
}

const OpCode = enum(u8) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
};

fn writeFrameHeader(writer: anytype, opcode: OpCode, payload_len: usize, compressed: bool) !void {
    var first_byte: u8 = @intFromEnum(opcode);
    first_byte |= 0x80;
    
    if (compressed) first_byte |= 0x40;
    try writer.writeByte(first_byte);
    
    if (payload_len < 126) {
        try writer.writeByte(@intCast(payload_len));
    } else if (payload_len <= 0xFFFF) {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, @intCast(payload_len), .big);
        try writer.writeAll(&buf);
    } else {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, payload_len, .big);
        try writer.writeAll(&buf);
    }
}

