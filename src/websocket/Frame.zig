pub const Frame = @This();

header: Header,
payload: Payload,

pub fn init(payload_buf: []u8, option: Option, config: zzz.Config) Frame {
    debug.assert(payload_buf.len <= config.recv_buffer_size.Usize());

    const payload_len, const payload_category = blk: {
        const size = if (option.opcode == .close)
            option.message.len + @sizeOf(http.Status)
        else
            option.message.len;

        const category: u7 = if (size <= 125)
            @intCast(size)
        else if (size < 1024 * 64) 126 else 127;

        break :blk .{ size, category };
    };

    debug.assert(payload_buf.len >= payload_len);

    const header: Header = .{
        .fin = option.fin,
        .mask = if (option.masking_key) |_| true else false,
        .opcode = option.opcode,
        .payload_len = payload_category,
    };

    var payload: Payload = .empty;

    switch (payload_category) {
        0...125 => {},
        126 => payload.extended_len = .{ .u16 = @intCast(payload_len) },
        127 => payload.extended_len = .{ .u64 = payload_len },
    }

    // never must be set by server response but here to test
    // client masking functionality
    if (option.masking_key) |masking_key| payload.masking_key = masking_key;

    // start of application payload
    if (option.status) |status| {
        debug.assert(option.opcode == .close);
        payload.status = status;
    }

    {
        if (option.masking_key) |masking_key| _ = unmask(
            payload_buf[0..option.message.len],
            option.message,
            masking_key,
        ) else @memcpy(payload_buf[0..option.message.len], option.message);

        payload.data = payload_buf[0..option.message.len];
    }

    return .{
        .header = header,
        .payload = payload,
    };
}

pub fn len(frame: *const Frame) usize {
    switch (frame.header.payload_len) {
        0...125 => |len_| return len_,
        126 => return frame.payload.extended_len.?.u16,
        127 => return frame.payload.extended_len.?.u64,
    }
}

pub fn format(
    frame: *const Frame,
    w: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try w.print("direct: {any}\n", .{frame});
    const header: [2]u8 = toBytes(@backingInt(frame.header));

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

            const raw = toBytes(frame.payload.extended_len.?.u16);
            hex(w, raw[0..]);
        },
        127 => {
            const size = @sizeOf(u64);
            defer index += size;

            const raw = toBytes(frame.payload.extended_len.?.u64);
            hex(w, raw[0..]);
        },
    }

    if (frame.payload.masking_key) |key| {
        try w.writeAll("\n\nMasking length\n");
        const mask_size = @sizeOf(MaskingKey);
        defer index += mask_size;

        const raw = toBytes(key);
        hex(w, raw[0..]);
    }

    if (frame.payload.status) |status| {
        try w.writeAll("\n\nPayload status\n");
        const mask_size = @sizeOf(http.Status);
        defer index += mask_size;

        try w.print("{t}", .{status});
    }

    try w.writeAll("\n\nPayload\n");
    try w.print("0x{X}", .{frame.payload.data});
}

test format {
    const msg: [126]u8 = @splat('A');

    var payload_buf: [msg.len + @sizeOf(http.Status)]u8 = undefined;
    const frame: Frame = .init(&payload_buf, .{
        .fin = true,
        .opcode = .close,
        .masking_key = 0xA,
        .status = .OK,
        .message = msg[0..],
    }, .{});

    const expected =
        \\Pretty:
        \\direct: .{ .header = .{ .payload_len = 126, .mask = true, .opcode = .close, .rsv1_3 = 0, .fin = true }, .payload = .{ .extended_len = .{ ... }, .masking_key = 10, .status = .OK, .data = { 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65, 65, 75, 65, 65 } } }
        \\
        \\Fin Opcode
        \\0x88
        \\
        \\Mask Toggle and Standard Payload length
        \\0xFE
        \\
        \\Extended Payload length
        \\0x000x80
        \\
        \\Masking length
        \\0x000x000x000x0A
        \\
        \\Payload status
        \\OK
        \\
        \\Payload
        \\0x4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141414B4141
    ;

    var fmt_buf: [expected.len * 2]u8 = undefined;
    const actual = try mem.print(&fmt_buf, "Pretty:\n{f}", .{
        frame,
    });

    try testing.expectEqualStrings(expected[0..], actual[0..]);
}

pub fn bytes(frame: *const Frame, buf: []u8) []const u8 {
    const raw = @backingInt(frame.header);
    const header: [2]u8 = toBytes(raw);

    var buf_index: usize = 0;
    // Header
    {
        defer buf_index += @sizeOf(Header);
        @memcpy(buf[0..header.len], header[0..]);
    }

    // Payload length
    switch (frame.header.payload_len) {
        0...125 => {},
        126 => {
            const size = @sizeOf(u16);
            defer buf_index += size;

            mem.writeInt(
                u16,
                buf[buf_index..][0..size],
                frame.payload.extended_len.?.u16,
                .big,
            );
        },
        127 => {
            const size = @sizeOf(u64);
            defer buf_index += size;

            mem.writeInt(
                u64,
                buf[buf_index..][0..size],
                frame.payload.extended_len.?.u64,
                .big,
            );
        },
    }

    // Masking length
    if (frame.payload.masking_key) |masking_key| {
        const mask_size = @sizeOf(MaskingKey);
        defer buf_index += mask_size;

        mem.writeInt(
            MaskingKey,
            buf[buf_index..][0..mask_size],
            masking_key,
            .big,
        );
    }

    if (frame.payload.status) |status| {
        debug.assert(frame.header.opcode == .close);

        const status_size = @sizeOf(http.Status); // 2 bytes
        defer buf_index += status_size;

        const status_data = buf[buf_index..];
        mem.writeInt(
            @typeInfo(http.Status).@"enum".tag_type,
            status_data[0..status_size],
            @backingInt(status),
            .big,
        );

        if (frame.payload.masking_key) |masking_key| _ = unmask(
            status_data[0..status_size],
            status_data[0..status_size],
            masking_key,
        );
    }

    // Payload
    {
        const payload_data = frame.payload.data;
        defer buf_index += payload_data.len;

        @memcpy(buf[buf_index..][0..payload_data.len], payload_data);
    }

    debug.assert(buf.len >= buf_index);

    return buf[0..buf_index];
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
        debug.assert(opcode.isData());

        const frame: Frame = .init(payload_buf, .{
            .fin = false,
            .opcode = opcode,
            .status = null,
            .message = data,
        }, .{});

        debug.assert(frame.header.isStart());

        return frame;
    }

    pub fn @"continue"(payload_buf: []u8, data: []const u8) Frame {
        const frame: Frame = .init(payload_buf, .{
            .fin = false,
            .opcode = .continuation,
            .status = null,
            .message = data,
        }, .{});

        debug.assert(frame.header.isContinue());

        return frame;
    }

    pub fn end(payload_buf: []u8, data: []const u8) Frame {
        const frame: Frame = .init(payload_buf, .{
            .fin = true,
            .opcode = .continuation,
            .status = null,
            .message = data,
        }, .{});

        debug.assert(frame.header.isEnd());

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

/// Convert `value` to an array of bytes in network bytes ordering
pub fn toBytes(value: anytype) [@sizeOf(@TypeOf(value))]u8 {
    const T = @TypeOf(value);
    debug.assert(@typeInfo(T).int.signedness == .unsigned);
    debug.assert(@mod(@typeInfo(T).int.bits, 8) == 0);

    var raw: [@sizeOf(T)]u8 = undefined;
    mem.writeInt(T, &raw, value, .big);

    return raw;
}

pub fn unmask(buf: []u8, masked_pl: []const u8, key: MaskingKey) []const u8 {
    debug.assert(buf.len >= masked_pl.len);

    const key_bytes: [4]u8 = toBytes(key);
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
pub const Header = packed struct(u16) {
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

    pub fn isControl(header: Header) bool {
        return header.opcode.isControl();
    }

    /// only valid when called on the first frame of the WebSocket
    pub fn isFragment(header: Header) bool {
        return header.opcode.isData() and header.fin == false;
    }

    /// Fragment Start
    pub fn isStart(header: Header) bool {
        return header.fin == false and header.opcode.isData();
    }

    /// Fragment Continue
    pub fn isContinue(header: Header) bool {
        return header.fin == false and header.opcode == .continuation;
    }

    /// Fragment End
    pub fn isEnd(header: Header) bool {
        return header.fin == true and header.opcode == .continuation;
    }

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

    pub fn isControl(opcode: Opcode) bool {
        return switch (opcode) {
            .continuation, .text, .binary => false,
            else => true,
        };
    }

    pub fn isData(opcode: Opcode) bool {
        return switch (opcode) {
            .text, .binary => true,
            else => false,
        };
    }
};

/// Multibyte values in `Payload` are expressed in Network Byte Order
pub const Payload = struct {
    /// `Payload` contains `extended_len` if `header.payload_len` >= 126
    /// if `header.payload_len` <= 125 then `header.payload_len` is the `payload_len`
    /// if `header.payload_len` == 126 then the next 2 bytes .ie `extended_len.u16` is `payload_len`
    /// if `header.payload_len` == 127 then the next 8 bytes .ie `extended_len.u64` is `payload_len`
    extended_len: ?union {
        u16: u16,
        u64: u64,
    },
    /// If `Frame` is sent by the client, the next 4 bytes is `masking_key`
    masking_key: ?u32,
    /// Remaining bytes are "Payload data"
    /// `status` is only set on `close` Frame
    status: ?http.Status,
    /// `Payload data` is defined as "Extension data" + "Application data"
    data: []const u8,

    pub const empty: Payload = .{
        .extended_len = null,
        .masking_key = null,
        .status = null,
        .data = "",
    };
};

const Option = struct {
    fin: bool,
    opcode: Opcode,
    /// must never be set by server response
    masking_key: ?MaskingKey = null,
    status: ?http.Status = null,
    message: []const u8,
};

pub const MaskingKey = u32;

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
