pub fn start(
    secure: *zzz.Secsock,
    rt: *Runtime,
    zc_recv_buffer: *core.ZeroCopy(u8),
    config: zzz.Config,
) Frame {
    const frame = nextFrame(
        secure,
        rt,
        zc_recv_buffer,
        config,
    ).?;

    debug.assert(frame.header.fin == true or frame.header.isFragment());

    return collectFragments(
        frame,
        secure,
        rt,
        zc_recv_buffer,
        config,
    ) catch unreachable;
}

pub fn next(
    secure: *zzz.Secsock,
    rt: *Runtime,
    zc_recv_buffer: *core.ZeroCopy(u8),
    config: zzz.Config,
) ?Frame {
    const new_frame = nextFrame(
        secure,
        rt,
        zc_recv_buffer,
        config,
    ) orelse return null;

    return collectFragments(
        new_frame,
        secure,
        rt,
        zc_recv_buffer,
        config,
    ) catch unreachable;
}

fn collectFragments(
    frame: Frame,
    secure: *zzz.Secsock,
    rt: *Runtime,
    zc_recv_buffer: *core.ZeroCopy(u8),
    config: zzz.Config,
) error{OutOfMemory}!Frame {
    const is_fragment = frame.header.isFragment();
    if (is_fragment) {
        debug.assert(frame.header.isStart());

        var arena_alloc: std.heap.ArenaAllocator = .init(rt.gpa);
        const arena = arena_alloc.allocator();
        var frames: std.ArrayList(Frame) = try .initCapacity(
            arena,
            24,
        );
        defer frames.deinit(arena);

        try frames.append(arena, frame);

        while (nextFrame(
            secure,
            rt,
            zc_recv_buffer,
            config,
        )) |next_frame| {
            debug.assert(next_frame.header.isContinue() or next_frame.header.isEnd());

            if (next_frame.header.isControl()) debug.panic(
                "TODO: handle when it isn't a control frame",
                .{},
            );

            try frames.append(arena, next_frame);
        }

        var payload: std.ArrayList([]const u8) = .empty;
        for (frames.items) |frame_|
            try payload.append(arena, frame_.payload.data);

        const payload_data = try mem.concat(
            rt.gpa,
            u8,
            payload.items,
        );

        const frame_: Frame = .init(
            payload_data,
            .{
                .fin = true,
                .opcode = frame.header.opcode,
                .message = payload_data,
            },
            .{},
        );
        return frame_;
    }

    return frame;
}

fn header(secure: *zzz.Secsock, rt: *Runtime) ?Frame.Header {
    var bytes: [@sizeOf(Frame.Header)]u8 = undefined;
    const recv_count = secure.recv(rt, &bytes) catch |err|
        switch (err) {
            error.Closed => return null,
            else => unreachable,
        };
    debug.assert(bytes.len == recv_count);

    const raw = mem.readInt(u16, &bytes, .big);
    const header_frame: Frame.Header = @bitCast(raw);

    return header_frame;
}

fn nextFrame(
    secure: *zzz.Secsock,
    rt: *Runtime,
    zc_recv_buffer: *core.ZeroCopy(u8),
    config: zzz.Config,
) ?Frame {
    const head = header(secure, rt) orelse return null;
    var payload: Frame.Payload = .empty;

    const payload_buf = zc_recv_buffer.get_write_area(
        rt.gpa,
        if (head.isControl())
            Frame.Opcode.control_frame_payload_size_max
        else
            config.recv_buffer_size.Usize(),
    ) catch |err| debug.panic("{t}", .{err});

    var payload_index: usize = 0;
    switch (head.payload_len) {
        0...125 => {},
        126 => {
            const size = @sizeOf(u16);
            defer payload_index += size;

            const len_buf = payload_buf[payload_index..][0..size];

            const recv_count = secure.recv(
                rt,
                len_buf,
            ) catch |err| switch (err) {
                error.Closed => return null,
                else => unreachable,
            };
            defer zc_recv_buffer.mark_written(recv_count);

            debug.assert(recv_count == size);

            const payload_len = mem.readInt(
                u16,
                len_buf,
                .big,
            );
            payload.extended_len = .{ .u16 = payload_len };
        },
        127 => {
            const size = @sizeOf(u64);
            defer payload_index += size;

            const len_buf = payload_buf[payload_index..][0..size];

            const payload_size = secure.recv(
                rt,
                len_buf,
            ) catch |err| switch (err) {
                error.Closed => return null,
                else => unreachable,
            };
            defer zc_recv_buffer.mark_written(payload_size);

            debug.assert(payload_size == size);

            const payload_len = mem.readInt(u64, len_buf, .big);

            payload.extended_len = .{ .u64 = payload_len };
        },
    }

    if (head.mask) {
        const mask_size = @sizeOf(Frame.MaskingKey);
        defer payload_index += mask_size;

        const mask_buf =
            payload_buf[payload_index..][0..mask_size];

        const masking_key_size = secure.recv(
            rt,
            mask_buf,
        ) catch unreachable;
        defer zc_recv_buffer.mark_written(masking_key_size);

        debug.assert(masking_key_size == mask_size);

        payload.masking_key = mem.readInt(
            Frame.MaskingKey,
            mask_buf,
            .big,
        );
    }

    var frame: Frame = .{
        .header = head,
        .payload = payload,
    };

    {
        const payload_len = frame.len();
        defer payload_index += payload_len;

        const payload_data = payload_buf[payload_index..][0..payload_len];

        // Autobahn test allows 0-length payloads
        if (payload_len > 0) {
            const recv_count = secure.recv(
                rt,
                payload_data,
            ) catch unreachable;
            defer zc_recv_buffer.mark_written(recv_count);

            debug.assert(recv_count == payload_len);
        }

        if (frame.payload.masking_key) |masking_key| _ = Frame.unmask(
            payload_data,
            payload_data,
            masking_key,
        );

        switch (head.opcode) {
            .close => {
                const status_size = @sizeOf(status.Close);
                const status_close = payload_data[0..status_size];
                const raw = mem.readInt(
                    @typeInfo(status.Close).@"enum".tag_type,
                    status_close,
                    .big,
                );
                frame.payload.status = @fromBackingInt(raw);
                frame.payload.data = payload_data[status_size..];
            },
            else => frame.payload.data = payload_data,
        }
    }

    return frame;
}

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const builtin = @import("builtin");

const zzz = @import("zzz");
const status = @import("status.zig");
const Secsock = zzz.Secsock;
const tardy = zzz.tardy;
const core = tardy.core;
const Runtime = tardy.Runtime;

const Frame = @import("Frame.zig");
