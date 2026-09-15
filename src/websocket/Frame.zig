pub const Frame = @This();

header: Header,
/// `payload` contains `payload_len` if `header.payload_len` >= 126
/// Multibyte length in `payload` are expressed in Network Byte Order
/// if `header.payload_len` <= 125 `header.payload_len` is the `payload_len`
/// if `header.payload_len` == 126 next 2 bytes are `payload_len`
/// if `header.payload_len` == 127 next 8 bytes are `payload_len`
///
/// If `Frame` is sent by client next 4 bytes are `masking_key`
/// masking_key: u32,
///
/// Remaining bytes are "Payload data"
/// `payload` is defined as "Extension data" + "Application data"
payload: []const u8,

fn init(payload_buf: []u8, option: Option, config: zzz.Config) Frame {
    debug.assert(payload_buf.len <= config.recv_buffer_size.Usize());

    const payload_len = blk: {
        break :blk if (option.status) |_|
            option.message.len + @sizeOf(http.Status)
        else
            option.message.len;
    };

    const header: Header = .{
        .fin = option.fin,
        .mask = if (option.masking_key) |_| true else false,
        .opcode = option.opcode,
        .payload_len = if (payload_len <= 125) @intCast(payload_len) else 0,
    };

    var payload_index: usize = 0;
    switch (payload_len) {
        126 => {
            const size = @sizeOf(u16);
            defer payload_index += size;

            mem.writeInt(
                u16,
                payload_buf[0..size],
                @intCast(payload_len),
                .big,
            );
        },
        127 => {
            const size = @sizeOf(u64);
            defer payload_index += size;

            mem.writeInt(
                u64,
                payload_buf[0..size],
                payload_len,
                .big,
            );
        },
        else => {},
    }

    // never must be set by server response but here to test
    // client masking functionality
    if (option.masking_key) |masking_key| {
        const size = @sizeOf(MaskingKey);
        defer payload_index += size;

        mem.writeInt(
            MaskingKey,
            payload_buf[0..size],
            masking_key,
            .big,
        );
    }

    // start of application payload
    if (option.status) |status| {
        const status_size = @sizeOf(http.Status); // 2 bytes
        defer payload_index += status_size;

        const status_data = payload_buf[payload_index..];
        mem.writeInt(
            @typeInfo(http.Status).@"enum".tag_type,
            status_data[0..status_size],
            @backingInt(status),
            .big,
        );

        if (option.masking_key) |masking_key| {
            _ = mask(
                status_data[0..status_size],
                status_data[0..status_size],
                masking_key,
            );
        }
    }

    {
        const application_data = payload_buf[payload_index..];
        defer payload_index += option.message.len;

        @memcpy(application_data[0..option.message.len], option.message);

        if (option.masking_key) |masking_key| {
            _ = mask(
                application_data[0..option.message.len],
                application_data[0..option.message.len],
                masking_key,
            );
        }
    }

    // payload length does NOT include the length of the masking key
    if (option.masking_key) |_|
        debug.assert(payload_index - @sizeOf(MaskingKey) == payload_len)
    else
        debug.assert(payload_index == payload_len);

    const new: Frame = .{
        .header = header,
        // we use `payload_index` because `payload_len` doesn't account
        // for the potential `masking_key` in the `payload` bytes
        .payload = payload_buf[0..payload_index],
    };

    return new;
}

fn payloadLen(frame: *const Frame) usize {
    switch (frame.header.payload_len) {
        0...125 => |len| return @intCast(len),
        126 => {
            const size = @sizeOf(u16);
            const payload_len = frame.payload[0..size];
            const len = mem.readInt(u16, payload_len, .big);
            return @intCast(len);
        },
        127 => {
            const size = @sizeOf(u64);
            const payload_len = frame.payload[0..size];
            const len = mem.readInt(u64, payload_len, .big);
            return len;
        },
    }
}

fn maskKey(frame: *const Frame) ?u32 {
    const mask_size = @sizeOf(u32);
    if (frame.header.mask) switch (frame.header.payload_len) {
        0...125 => {
            const mask_pl = frame.payload[0..mask_size];
            const value = mem.readInt(u32, mask_pl, .big);
            return value;
        },
        126 => {
            const extended_len = @sizeOf(u16);
            const mask_pl = frame.payload[0..extended_len][0..mask_size];
            const value = mem.readInt(u32, mask_pl, .big);
            return value;
        },
        127 => {
            const extended_len = @sizeOf(u64);
            const mask_pl = frame.payload[0..extended_len][0..mask_size];
            const value = mem.readInt(u32, mask_pl, .big);
            return value;
        },
    };
    return null;
}

fn payloadData(frame: *const Frame) []const u8 {
    const mask_len = @sizeOf(u32);
    switch (frame.header.payload_len) {
        0...125 => {
            if (frame.header.mask) return frame.payload[mask_len..][0..];
            return frame.payload[0..];
        },
        126 => {
            const extended_len = @sizeOf(u16);
            if (frame.header.mask)
                return frame.payload[mask_len + extended_len ..][0..];
            return frame.payload[extended_len..];
        },
        127 => {
            const extended_len = @sizeOf(u64);
            if (frame.header.mask)
                return frame.payload[mask_len + extended_len ..][0..];
            return frame.payload[extended_len..];
        },
    }
}

pub fn format(
    frame: *const Frame,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try w.print("direct: {any}\n", .{frame});

    const header: [2]u8 = switch (endian) {
        .little => @bitCast(@byteSwap(@backingInt(frame.header))),
        .big => @bitCast(frame.header),
    };

    const hex = struct {
        fn hex(w_: *std.Io.Writer, loads: []const u8) void {
            for (loads) |load| {
                w_.print("0x{X:0>2}", .{load}) catch unreachable;
            }
        }
    }.hex;

    try w.writeAll("\nFin Opcode\n");
    hex(w, &.{header[0]});
    try w.writeByte('\n');

    try w.writeAll("\nMask Toggle and Standard Payload length\n");
    hex(w, &.{header[1]});
    try w.writeByte('\n');

    try w.writeAll("\nExtended Payload length\n");

    var index: usize = 0;

    // Payload length
    switch (frame.header.payload_len) {
        0...125 => {},
        126 => {
            const size = @sizeOf(u16);
            defer index += size;

            hex(w, frame.payload[index..size]);
        },
        127 => {
            const size = @sizeOf(u64);
            defer index += size;

            hex(w, frame.payload[index..size]);
        },
    }

    if (frame.header.mask) {
        try w.writeAll("\nMasking length\n");
        // Masking length
        const mask_size = @sizeOf(u32);
        defer index += mask_size;

        hex(w, frame.payload[index..][0..mask_size]);
    }

    // Payload
    try w.writeAll("\n\nPayload\n");
    const payload = frame.payload[index..];
    try w.print("0x{X}", .{payload[0..]});
}

test format {
    const msg = "Hello";

    var payload_buf: [5]u8 = undefined;
    const texting = text(
        &payload_buf,
        msg,
        .{},
    );

    var fmt_buf: [260]u8 = undefined;
    const actual = try mem.print(&fmt_buf, "Pretty:\n{f}", .{texting});

    const expected =
        \\Pretty:
        \\direct: .{ .header = .{ .payload_len = 5, .mask = false, .opcode = .text, .rsv1_3 = 0, .fin = true }, .payload = { 72, 101, 108, 108, 111 } }
        \\
        \\Fin Opcode
        \\0x81
        \\
        \\Mask Toggle and Standard Payload length
        \\0x05
        \\
        \\Extended Payload length
        \\
        \\
        \\Payload
        \\0x48656C6C6F
    ;

    try testing.expectEqualStrings(expected[0..], actual[0..]);
}

pub fn bytes(frame: *const Frame, buf: []u8) []const u8 {
    const raw = @backingInt(frame.header);
    const header: [2]u8 = toBytes(@TypeOf(raw), raw);

    var buf_index: usize = 0;
    {
        defer buf_index += @sizeOf(Header);
        @memcpy(buf[0..header.len], header[0..]);
    }

    var payload_index: usize = 0;
    // Payload length
    switch (frame.header.payload_len) {
        0...125 => {},
        126 => {
            const size = @sizeOf(u16);
            defer buf_index += size;
            defer payload_index += size;

            @memcpy(
                buf[buf_index..][0..size],
                frame.payload[payload_index..][0..size],
            );
        },
        127 => {
            const size = @sizeOf(u64);
            defer buf_index += size;
            defer payload_index += size;

            @memcpy(
                buf[buf_index..][0..size],
                frame.payload[payload_index..][0..size],
            );
        },
    }

    if (frame.header.mask) {
        // Masking length
        const mask_size = @sizeOf(MaskingKey);
        defer buf_index += mask_size;
        defer payload_index += mask_size;

        @memcpy(
            buf[buf_index..][0..mask_size],
            frame.payload[payload_index..][0..mask_size],
        );
    }

    // Payload
    {
        const payload = frame.payload[payload_index..];
        defer buf_index += payload.len;
        @memcpy(buf[buf_index..][0..payload.len], payload[0..]);
    }

    return buf[0..buf_index];
}

fn toBytes(t: type, value: t) [@sizeOf(t)]u8 {
    debug.assert(@typeInfo(t).int.signedness == .unsigned);
    debug.assert(@mod(@typeInfo(t).int.bits, 8) == 0);

    return @bitCast(switch (endian) {
        .little => @byteSwap(value),
        .big => @backingInt(value),
    });
}

pub fn text(payload_buf: []u8, utf8_text: []const u8, config: zzz.Config) Frame {
    const texting: Frame = .init(payload_buf, .{
        .fin = true,
        .opcode = .text,
        .message = utf8_text,
    }, config);

    return texting;
}

test text {
    const msg = "Hello";

    // A single-frame with unmasked text message
    {
        var payload_buf: [msg.len]u8 = undefined;
        const texting = text(
            &payload_buf,
            msg,
            .{},
        );

        const expected: [7]u8 = .{ 0x81, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f };

        var protocol_wire_buf: [expected.len]u8 = undefined;
        const actual = texting.bytes(&protocol_wire_buf);

        try testing.expectEqualSlices(u8, expected[0..], actual);
    }

    // A single-frame with masked text message
    {
        var payload_buf: [@sizeOf(MaskingKey) + msg.len]u8 = undefined;
        const texting: Frame = .init(&payload_buf, .{
            .fin = true,
            .masking_key = 0x37_FA_21_3D,
            .opcode = .text,
            .message = msg,
        }, .{});

        const expected: [11]u8 = .{
            0x81, 0x85, // Header
            0x37, 0xfa, 0x21, 0x3d, // Mask
            0x7f, 0x9f, 0x4d, 0x51, 0x58, // Payload
        };

        var protocol_wire_buf: [expected.len]u8 = undefined;
        const actual = texting.bytes(&protocol_wire_buf);

        try testing.expectEqualSlices(u8, expected[0..], actual);
    }
}

/// A Ping frame may serve either as a keepalive or as a means to
/// verify that the remote endpoint is still responsive
pub fn ping(payload_buf: []u8, reason: []const u8) Frame {
    debug.assert(reason.len <= Opcode.control_frame_payload_size_max);

    const pinging: Frame = .init(payload_buf, .{
        .fin = false,
        .opcode = .ping,
        .message = reason,
    }, .{});

    return pinging;
}

pub fn binary(payload_buf: []u8, data: []const u8, config: zzz.Config) Frame {
    const bin: Frame = .init(payload_buf, .{
        .fin = false,
        .opcode = .binary,
        .message = data,
    }, config);

    return bin;
}

pub fn pong(payload_buf: []u8, reason: []const u8) Frame {
    debug.assert(reason.len <= Opcode.control_frame_payload_size_max);

    const ponging: Frame = .init(payload_buf, .{
        .fin = false,
        .opcode = .ping,
        .message = reason,
    }, .{});

    return ponging;
}

pub fn close(payload_buf: []u8, status: http.Status, reason: []const u8) Frame {
    debug.assert(payload_buf.len >= Opcode.control_frame_payload_size_max);

    const closing: Frame = .init(payload_buf, .{
        .fin = true,
        .opcode = .close,
        .status = status,
        .message = reason,
    }, .{});

    return closing;
}

fn mask(buf: []u8, payload: []const u8, key: u32) []const u8 {
    return unmask(buf, payload, key);
}

fn unmask(buf: []u8, masked_pl: []const u8, key: u32) []const u8 {
    debug.assert(buf.len >= masked_pl.len);

    const key_bytes: [4]u8 = toBytes(@TypeOf(key), key);
    var transformed: []u8 = buf[0..masked_pl.len];
    for (masked_pl, 0..) |octect, i| {
        const j: usize = @mod(i, 4);
        transformed[i] = octect ^ key_bytes[j];
    }
    return transformed;
}

test unmask {
    var masked: [5]u8 = .{ 0x7f, 0x9f, 0x4d, 0x51, 0x58 };
    const unmasked: [5]u8 = .{ 'H', 'e', 'l', 'l', 'o' };

    _ = unmask(
        &masked,
        masked[0..],
        0x37_FA_21_3D,
    );
    try testing.expectEqualSlices(u8, unmasked[0..], masked[0..]);
}

/// When encoded on the wire, the most significant bit is the leftmost
/// This is the opposite of Zig's packed struct as it is interpreted as a
/// logical sequence of bits, arranged from least to most significant
/// So we reverse the order of the bit fields to ensure it aligns with the
/// specs requirement of most to least significant bit ordering
const Header = packed struct(u16) {
    /// The payload length is the length of the "Extension data" + the length of
    /// the "Application data"
    payload_len: u7,
    /// Defines whether the "Payload data" is masked. If enabled, a masking key is
    /// present, and this is used to unmask the "Payload data" as per Section 5.3.
    /// All frames sent from client to server must have this bit enabled.
    mask: bool,
    opcode: Opcode,
    rsv1_3: u3 = 0,
    /// Indicates that this is the final fragment in a message
    fin: bool,

    comptime {
        debug.assert(@alignOf(Header) == 2);
        debug.assert(@bitSizeOf(Header) == 16);
        debug.assert(@sizeOf(Header) == 2);
    }
};

/// Defines the interpretation of the "Payload data"
pub const Opcode = enum(u4) {
    /// 0x0 denotes a continuation frame
    continuation = 0x0,

    // NON-CONTROL FRAME

    /// 0x1 denotes a text frame
    text = 0x1,
    /// 0x2 denotes a binary frame
    binary = 0x2,

    /// 0x3-0x7 are reserved for further non-control frames

    // CONTROL FRAME

    /// 0x8 denotes a connection close
    close = 0x8,
    /// 0x9 denotes a ping
    ping = 0x9,
    /// 0xA denotes a pong
    pong = 0xA,

    /// 0xB-0xF are reserved for further control frames
    _,

    pub const control_frame_payload_size_max = 125;
};

const Option = struct {
    fin: bool,
    opcode: Opcode,
    /// must never be set by server response
    masking_key: ?u32 = null,
    status: ?http.Status = null,
    message: []const u8,
};

const MaskingKey = u32;

const std = @import("std");
const log = std.log.scoped(.@"websocket/framing");
const debug = std.debug;
const mem = std.mem;
const testing = std.testing;
const builtin = @import("builtin");
const endian = builtin.target.cpu.arch.endian();

const zzz = @import("zzz");
const http = zzz.http;
