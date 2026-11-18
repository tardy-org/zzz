pub fn handshake(
    rt: *zzz.tardy.Runtime,
    secure: *zzz.Secsock,
    provision: *Server.Provision,
    config: zzz.Config,
) !Server.State {
    const handshake_buf = try provision.zc_recv_buffer.get_write_area(
        rt.gpa,
        config.recv_buffer_size.Usize(),
    );

    const byte_count = secure.recv(
        rt,
        handshake_buf,
    ) catch |e| switch (e) {
        error.Closed => return .{ .respond = .close },
        else => |err| {
            log.err(
                "handshake recv failed on socket | {t}",
                .{err},
            );
            return .{ .respond = .close };
        },
    };
    provision.zc_recv_buffer.mark_written(byte_count);

    if (provision.zc_recv_buffer.len() > config.request_size_max.Usize())
        return .{ .respond = .close };

    const end_marker = "\r\n\r\n";
    if (!mem.endsWith(
        u8,
        handshake_buf[0..byte_count],
        end_marker,
    )) {
        const respond = try provision.handshake.response.apply(.{
            .status = .@"Bad Request",
            .mime = .TEXT,
            .body = "Check if using https/http incorrectly in the request.\n",
        });
        return .{ .respond = respond };
    }

    try provision.handshake.request.parse(
        rt.gpa,
        handshake_buf[0..byte_count],
        .{
            .request_bytes_max = config.request_size_max,
            .request_uri_bytes_max = config.request_uri_size_max,
        },
    );

    debug.assert(mem.findScalar(
        u8,
        provision.handshake.request.uri.?,
        '#',
    ) == null);

    debug.assert(provision.handshake.request.method.? == .GET);

    const upgrade = provision.handshake.request.headers.get("Upgrade").?;
    debug.assert(
        mem.eql(u8, upgrade, "websocket") or
            mem.eql(u8, upgrade, "WebSocket"),
    );

    debug.assert(mem.eql(
        u8,
        provision.handshake.request.headers.get("Connection").?,
        "Upgrade",
    ));
    debug.assert((std.fmt.parseInt(
        u32,
        provision.handshake.request.headers.get("Sec-WebSocket-Version").?,
        10,
    ) catch unreachable) == protocal_version);

    if (provision.handshake.request.headers.get(
        "Sec-WebSocket-Protocol",
    )) |protocals| {
        var itr = mem.tokenizeScalar(
            u8,
            protocals,
            ',',
        );
        while (itr.next()) |protocal| {
            debug.assert(protocal.len != 0);
            try provision.protocals.putNoClobber(
                rt.gpa,
                protocal,
                {},
            );
        }
    }

    if (provision.handshake.request.headers.get(
        "Sec-WebSocket-Extensions",
    )) |extensions| {
        var itr = mem.tokenizeScalar(
            u8,
            extensions,
            ';',
        );
        while (itr.next()) |extension| {
            debug.assert(extension.len != 0);
            try provision.extensions.putNoClobber(
                rt.gpa,
                extension,
                {},
            );
        }
    }

    const secure_info = secure.info();
    log.info("rt{d} - '{t} {s}' - {s} - ({s})", .{
        rt.id,
        provision.handshake.request.method.?,
        provision.handshake.request.uri.?,
        provision.handshake.request.headers.get("User-Agent") orelse "N/A",
        secure_info.address,
    });

    // Prepare Server Responses
    provision.handshake.response.status = .@"Switching Protocols";
    provision.handshake.response.headers.putAssumeCapacityNoClobber(
        "Upgrade",
        provision.handshake.request.headers.get("Upgrade").?,
    );
    provision.handshake.response.headers.putAssumeCapacityNoClobber(
        "Connection",
        provision.handshake.request.headers.get("Connection").?,
    );

    // TODO: protocal selection should be based on the servers support
    if (provision.protocals.count() != 0)
        provision.handshake.response.headers.putAssumeCapacityNoClobber(
            "Sec-WebSocket-Protocol",
            provision.protocals.keys()[0],
        );

    const handshake_accept_key = handshaker.acceptKey(
        rt.gpa,
        provision.handshake.request.headers.get("Sec-WebSocket-Key").?,
    );

    provision.handshake.response.headers.putAssumeCapacityNoClobber(
        "Sec-WebSocket-Accept",
        handshake_accept_key[0..],
    );

    try provision.handshake.response.writeHeaders(
        &provision.header_writer,
        null,
    );
    const headers = provision.header_writer.buffered();

    const sent_length = secure.send_all(
        rt,
        headers,
    ) catch |err| {
        log.err("handshake: send failed on socket | {t}", .{err});
        return .{ .respond = .close };
    };
    if (sent_length != headers.len) return .{ .respond = .close };

    return .{ .handler = {} };
}

pub fn handler(
    rt: *zzz.tardy.Runtime,
    router: *const Router,
    secure: *zzz.Secsock,
    provision: *Server.Provision,
) !Server.State {
    const routing = try router.routingInfo(
        rt.gpa,
        provision.handshake.request.uri.?,
        provision.captures,
        &provision.queries,
    );

    const handler_: Route.Handler.WithData = routing.route.handler(
        provision.handshake.request.method.?,
    ) orelse {
        provision.handshake.response.headers.clearRetainingCapacity();
        provision.handshake.response.status = .@"Method Not Allowed";
        provision.handshake.response.mime = .TEXT;
        provision.handshake.response.body = null;

        return .{ .respond = .responding };
    };

    const ctx: http.Context = .{
        .runtime = rt,
        .arena = provision.arena.allocator(),
        .header_writer = &provision.header_writer,
        .request = &provision.handshake.request,
        .response = &provision.handshake.response,
        .storage = &provision.storage,
        .websocket = .{
            .request = &provision.request,
            .response = &provision.response,
        },
        .tls = secure,
        .captures = routing.captures,
        .queries = routing.queries,
    };

    var next: Middleware.Next = .{
        .ctx = &ctx,
        .middlewares = handler_.middlewares,
        .handler = handler_,
    };

    // Note that the request handler sets the `ctx.response` when run
    const respond: http.Respond = next.run() catch |err| respond: {
        const secure_info = secure.info();
        log.err("rt{d} - \"{t} {s}\" {t} ({s})", .{
            rt.id,
            provision.handshake.request.method.?,
            provision.handshake.request.uri.?,
            err,
            secure_info.address,
        });

        // If in Debug Mode, we will return the error name. In other modes,
        // we won't to avoid leaking implemenation details.
        const body = if (comptime builtin.mode == .debug)
            @errorName(err)
        else
            "";

        break :respond try provision.handshake.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = .TEXT,
            .body = body,
        });
    };

    return .{ .respond = respond };
}

pub fn response(
    rt: *zzz.tardy.Runtime,
    secure: *zzz.Secsock,
    provision: *Server.Provision,
    config: zzz.Config,
    respond: http.Respond,
) !Server.State {
    switch (respond) {
        .responding => {
            const frame = &provision.response;

            const protocol_buf =
                try provision.zc_recv_buffer.get_write_area(
                    rt.gpa,
                    if (frame.header.isControl())
                        Frame.Opcode.control_frame_payload_size_max
                    else
                        config.recv_buffer_size.Usize(),
                );

            const protocol_bytes: []const u8 = frame.toBytes(protocol_buf);
            provision.zc_recv_buffer.mark_written(protocol_bytes.len);

            const sent_length = secure.send_all(
                rt,
                protocol_bytes,
            ) catch |err| {
                log.err("Frame {t}: send failed on socket | {t}", .{
                    frame.header.opcode,
                    err,
                });
                return .{ .respond = .close };
            };

            if (sent_length != protocol_bytes.len) {
                log.err(
                    "Frame {t}: sent {d} but was expected to send {d}",
                    .{ frame.header.opcode, sent_length, protocol_bytes.len },
                );
                return .{ .respond = .close };
            }

            switch (frame.header.opcode) {
                .close => {
                    return .{ .respond = .close };
                },
                else => return .{ .communication = .receive },
            }
        },
        .responded => unreachable,
        .close => return .{ .respond = .close },
    }
}

const log = std.log.scoped(.@"websocket/loop");
/// WebSocket protocal version
const protocal_version = 13;

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const builtin = @import("builtin");

const zzz = @import("zzz");
const http = zzz.http;
const Router = http.Router;
const Route = Router.Route;
const Middleware = Router.Middleware;

const handshaker = @import("handshake.zig");
const Server = @import("Server.zig");
const Frame = @import("Frame.zig");
