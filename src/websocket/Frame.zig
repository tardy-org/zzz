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

    const payload_size, const payload_category = blk: {
        const len = if (option.status) |_|
            option.message.len + @sizeOf(http.Status)
        else
            option.message.len;

        const category: u7 = if (len <= 125)
            @intCast(len)
        else if (len < 1024 * 64) 126 else 127;

        break :blk .{ len, category };
    };

    const min_buf_size = blk: {
        var size = option.message.len;
        if (option.status) |_| size += @sizeOf(http.Status);
        if (option.masking_key) |_| size += @sizeOf(MaskingKey);
        switch (payload_category) {
            126 => size += @sizeOf(u16),
            127 => size += @sizeOf(u64),
            else => {},
        }
        break :blk size;
    };
    debug.assert(payload_buf.len >= min_buf_size);

    const header: Header = .{
        .fin = option.fin,
        .mask = if (option.masking_key) |_| true else false,
        .opcode = option.opcode,
        .payload_len = payload_category,
    };

    var payload_len: usize = 0;
    switch (payload_category) {
        126 => {
            const size = @sizeOf(u16);
            defer payload_len += size;

            mem.writeInt(
                u16,
                payload_buf[0..size],
                @intCast(payload_size),
                .big,
            );
        },
        127 => {
            const size = @sizeOf(u64);
            defer payload_len += size;

            mem.writeInt(
                u64,
                payload_buf[0..size],
                payload_size,
                .big,
            );
        },
        else => {},
    }

    // never must be set by server response but here to test
    // client masking functionality
    if (option.masking_key) |masking_key| {
        const size = @sizeOf(MaskingKey);
        defer payload_len += size;

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
        defer payload_len += status_size;

        const status_data = payload_buf[payload_len..];
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
        const application_data = payload_buf[payload_len..];
        defer payload_len += option.message.len;

        @memcpy(application_data[0..option.message.len], option.message);

        if (option.masking_key) |masking_key| {
            _ = mask(
                application_data[0..option.message.len],
                application_data[0..option.message.len],
                masking_key,
            );
        }
    }

    {
        var total_size = payload_len;
        // payload length does NOT include the length of the masking key
        if (option.masking_key) |_|
            total_size -= @sizeOf(MaskingKey);

        switch (payload_category) {
            126 => total_size -= @sizeOf(u16),
            127 => total_size -= @sizeOf(u64),
            else => {},
        }
        debug.assert(total_size == payload_size);
    }

    const new: Frame = .{
        .header = header,
        // we use `payload_index` because `payload_len` doesn't account
        // for the potential `masking_key` in the `payload` bytes
        .payload = payload_buf[0..payload_len],
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

fn maskKey(frame: *const Frame) ?MaskingKey {
    const mask_size = @sizeOf(MaskingKey);
    if (frame.header.mask) switch (frame.header.payload_len) {
        0...125 => {
            const mask_pl = frame.payload[0..mask_size];
            const value = mem.readInt(MaskingKey, mask_pl, .big);
            return value;
        },
        126 => {
            const extended_len = @sizeOf(u16);
            const mask_pl = frame.payload[0..extended_len][0..mask_size];
            const value = mem.readInt(MaskingKey, mask_pl, .big);
            return value;
        },
        127 => {
            const extended_len = @sizeOf(u64);
            const mask_pl = frame.payload[0..extended_len][0..mask_size];
            const value = mem.readInt(MaskingKey, mask_pl, .big);
            return value;
        },
    };
    return null;
}

fn payloadData(frame: *const Frame) []const u8 {
    const mask_len = @sizeOf(MaskingKey);
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
    const raw = @backingInt(frame.header);
    const header: [2]u8 = toBytes(@TypeOf(raw), raw);

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
        const mask_size = @sizeOf(MaskingKey);
        defer index += mask_size;

        hex(w, frame.payload[index..][0..mask_size]);
    }

    try w.writeAll("\n\nPayload\n");
    const payload = frame.payload[index..];
    try w.print("0x{X}", .{payload[0..]});
}

test format {
    const msg = "Hello";

    var payload_buf: [msg.len]u8 = undefined;
    const texting = text(
        &payload_buf,
        msg,
        .{},
    );

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

    var fmt_buf: [expected.len]u8 = undefined;
    const actual = try mem.print(&fmt_buf, "Pretty:\n{f}", .{
        texting,
    });

    try testing.expectEqualStrings(expected[0..], actual[0..]);
}

pub fn bytes(frame: *const Frame, buf: []u8) []const u8 {
    const raw = @backingInt(frame.header);
    const header: [2]u8 = toBytes(@TypeOf(raw), raw);

    var buf_index: usize = 0;
    // Header
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

    // Masking length
    if (frame.header.mask) {
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
        .fin = true,
        .opcode = .ping,
        .message = reason,
    }, .{});

    return pinging;
}

test ping {
    const msg = "Hello";

    var ping_buf: [msg.len]u8 = undefined;
    // unmasked server ping with `msg`
    const pinging = ping(&ping_buf, msg);

    const expected: [7]u8 = .{ 0x89, 0x05, 0x48, 0x65, 0x6c, 0x6c, 0x6f };

    var protocol_wire_buf: [expected.len]u8 = undefined;
    const actual = pinging.bytes(&protocol_wire_buf);

    try testing.expectEqualSlices(u8, expected[0..], actual);
}

pub fn pong(payload_buf: []u8, reason: []const u8) Frame {
    debug.assert(reason.len <= Opcode.control_frame_payload_size_max);

    const ponging: Frame = .init(payload_buf, .{
        .fin = true,
        .opcode = .pong,
        .message = reason,
    }, .{});

    return ponging;
}

test pong {
    const msg = "Hello";

    // masked Pong response from client
    var ping_buf: [@sizeOf(MaskingKey) + msg.len]u8 = undefined;
    const pinging: Frame = .init(&ping_buf, .{
        .fin = true,
        .opcode = .pong,
        .masking_key = 0x37_FA_21_3D,
        .message = msg,
    }, .{});

    const expected: [11]u8 = .{
        0x8a, 0x85, // Header
        0x37, 0xfa, 0x21, 0x3d, // MaskingKey
        0x7f, 0x9f, 0x4d, 0x51, 0x58, // Payload
    };

    var protocol_wire_buf: [expected.len]u8 = undefined;
    const actual = pinging.bytes(&protocol_wire_buf);

    try testing.expectEqualSlices(u8, expected[0..], actual);
}

pub fn binary(payload_buf: []u8, data: []const u8) Frame {
    const bin: Frame = .init(payload_buf, .{
        .fin = true,
        .opcode = .binary,
        .message = data,
    }, .{});

    return bin;
}

test binary {
    // 256 bytes binary message in a single unmasked frame
    {
        const msg: [256]u8 = @splat(0);

        var bin_buf: [@sizeOf(u16) + msg.len]u8 = undefined;
        const binary_frame = binary(&bin_buf, msg[0..]);

        const expected: [@sizeOf(Header) + @sizeOf(u16) + msg.len]u8 = .{
            0x82, 0x7E, // Header
            0x01, 0x00, // u16 Extended payload len
        } ++ msg;

        var protocol_wire_buf: [expected.len]u8 = undefined;
        const actual = binary_frame.bytes(&protocol_wire_buf);

        try testing.expectEqualSlices(u8, expected[0..], actual);
    }

    // 64KiB binary message in a single unmasked frame
    {
        const msg: [64 * 1024]u8 = @splat(0);

        var bin_buf: [@sizeOf(u64) + msg.len]u8 = undefined;
        const binary_frame = binary(&bin_buf, msg[0..]);

        const expected: [@sizeOf(Header) + @sizeOf(u64) + msg.len]u8 = .{
            0x82, 0x7F, // Header
            0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, // u64 Extended payload len
        } ++ msg;

        var protocol_wire_buf: [expected.len]u8 = undefined;
        const actual = binary_frame.bytes(&protocol_wire_buf);

        try testing.expectEqualSlices(u8, expected[0..], actual);
    }
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

pub const Fragment = struct {
    pub fn start(payload_buf: []u8, opcode: Opcode, data: []const u8) Frame {
        debug.assert(opcode != .continuation);

        const frame: Frame = .init(payload_buf, .{
            .fin = false,
            .opcode = opcode,
            .status = null,
            .message = data,
        }, .{});

        return frame;
    }

    pub fn @"continue"(payload_buf: []u8, data: []const u8) Frame {
        const frame: Frame = .init(payload_buf, .{
            .fin = false,
            .opcode = .continuation,
            .status = null,
            .message = data,
        }, .{});

        return frame;
    }

    pub fn end(payload_buf: []u8, data: []const u8) Frame {
        const frame: Frame = .init(payload_buf, .{
            .fin = true,
            .opcode = .continuation,
            .status = null,
            .message = data,
        }, .{});

        return frame;
    }

    // A fragmented unmasked text message
    test Fragment {
        {
            const msg = "Hel";

            var payload_buf: [msg.len]u8 = undefined;
            const frame = start(
                &payload_buf,
                .text,
                msg,
            );

            const expected: [5]u8 = .{ 0x01, 0x03, 0x48, 0x65, 0x6c };

            var protocol_wire_buf: [expected.len]u8 = undefined;
            const actual = frame.bytes(&protocol_wire_buf);

            try testing.expectEqualSlices(
                u8,
                expected[0..],
                actual,
            );
        }

        {
            const msg = "lo";

            var payload_buf: [msg.len]u8 = undefined;
            const frame = @"continue"(
                &payload_buf,
                msg,
            );

            const expected: [4]u8 = .{ 0x00, 0x02, 0x6c, 0x6f };

            var protocol_wire_buf: [expected.len]u8 = undefined;
            const actual = frame.bytes(&protocol_wire_buf);

            try testing.expectEqualSlices(
                u8,
                expected[0..],
                actual,
            );
        }

        {
            const msg = "done";

            var payload_buf: [msg.len]u8 = undefined;
            const frame = end(
                &payload_buf,
                msg,
            );

            const expected: [6]u8 = .{ 0x80, 0x04, 0x64, 0x6f, 0x6e, 0x65 };

            var protocol_wire_buf: [expected.len]u8 = undefined;
            const actual = frame.bytes(&protocol_wire_buf);

            try testing.expectEqualSlices(
                u8,
                expected[0..],
                actual,
            );
        }
    }
};

fn mask(buf: []u8, payload: []const u8, key: MaskingKey) []const u8 {
    return unmask(buf, payload, key);
}

fn unmask(buf: []u8, masked_pl: []const u8, key: MaskingKey) []const u8 {
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
    masking_key: ?MaskingKey = null,
    status: ?http.Status = null,
    message: []const u8,
};

const MaskingKey = u32;

test {
    std.testing.refAllDecls(@This());
}

const log = std.log.scoped(.@"websocket/framing");
const endian = builtin.target.cpu.arch.endian();

const std = @import("std");
const debug = std.debug;
const mem = std.mem;
const testing = std.testing;
const builtin = @import("builtin");

const zzz = @import("zzz");
const http = zzz.http;
