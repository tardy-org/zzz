fn header(secure: *zzz.Secsock, rt: *Runtime) Frame.Header {
    var frame: Frame.Header = undefined;
    const header_size = secure.recv(
        rt,
        mem.asBytes(&frame),
    ) catch unreachable;
    debug.assert(header_size == @sizeOf(Frame.Header));
    return frame;
}

pub fn first(
    secure: *zzz.Secsock,
    rt: *Runtime,
    zc_recv_buffer: *core.ZeroCopy(u8),
    config: zzz.Config,
) Frame {
    const frame = next(
        secure,
        rt,
        zc_recv_buffer,
        config,
    ).?;

    debug.assert(frame.header.fin == true or frame.header.isFragment());

    return frame;
}

pub fn next(
    secure: *zzz.Secsock,
    rt: *Runtime,
    zc_recv_buffer: *core.ZeroCopy(u8),
    config: zzz.Config,
) ?Frame {
    const head = header(secure, rt);
    var payload: Frame.Payload = .empty;

    const payload_buf =
        zc_recv_buffer.get_write_area(
            rt.gpa,
            if (head.isControl())
                Frame.Opcode.control_frame_payload_size_max
            else
                config.recv_buffer_size.Usize(),
        ) catch |err| debug.panic("{t}", .{err});

    switch (head.payload_len) {
        0...125 => {},
        126 => {
            const len_buf = payload_buf[zc_recv_buffer.len()..][0..@sizeOf(u16)];
            const payload_size = secure.recv(
                rt,
                len_buf,
            ) catch |err| switch (err) {
                error.Closed => return null,
                else => unreachable,
            };
            defer zc_recv_buffer.mark_written(payload_size);

            debug.assert(payload_size == @sizeOf(u16));

            const payload_len = mem.readInt(
                u16,
                len_buf,
                endian,
            );
            payload.extended_len = .{ .u16 = payload_len };
        },
        127 => {
            const len_buf = payload_buf[zc_recv_buffer.len()..][0..@sizeOf(u64)];
            const payload_size = secure.recv(
                rt,
                len_buf,
            ) catch |err| switch (err) {
                error.Closed => return null,
                else => unreachable,
            };
            defer zc_recv_buffer.mark_written(payload_size);

            debug.assert(payload_size == @sizeOf(u64));

            const payload_len = mem.readInt(
                u64,
                len_buf,
                endian,
            );

            payload.extended_len = .{ .u64 = payload_len };
        },
    }

    if (head.mask) {
        const mask_buf =
            payload_buf[zc_recv_buffer.len()..][0..@sizeOf(Frame.MaskingKey)];

        const masking_key_size = secure.recv(
            rt,
            mask_buf,
        ) catch unreachable;
        defer zc_recv_buffer.mark_written(masking_key_size);

        debug.assert(masking_key_size == @sizeOf(Frame.MaskingKey));

        payload.masking_key = mem.readInt(
            Frame.MaskingKey,
            mask_buf,
            endian,
        );
    }

    var frame: Frame = .{
        .header = head,
        .payload = payload,
    };

    {
        const payload_data = payload_buf[zc_recv_buffer.len()..][0..frame.len()];

        const payload_size = secure.recv(
            rt,
            payload_data,
        ) catch unreachable;
        defer zc_recv_buffer.mark_written(payload_size);

        debug.assert(payload_size == frame.len());

        if (frame.payload.masking_key) |masking_key| _ = Frame.unmask(
            payload_data,
            payload_data,
            masking_key,
        );

        switch (head.opcode) {
            .close => {
                const status_size = @sizeOf(http.Status); // 2 bytes
                const status = payload_data[0..status_size];

                frame.payload.status = @fromBackingInt(mem.readInt(
                    @typeInfo(http.Status).@"enum".tag_type,
                    status,
                    endian,
                ));
                frame.payload.data = payload_data[status_size..];
            },
            else => frame.payload.data = payload_data,
        }
    }

    return frame;
}

const endian = builtin.target.cpu.arch.endian();

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const builtin = @import("builtin");

const zzz = @import("zzz");
const http = zzz.http;
const Secsock = zzz.Secsock;
const tardy = zzz.tardy;
const core = tardy.core;
const Runtime = tardy.Runtime;

const Frame = @import("Frame.zig");
