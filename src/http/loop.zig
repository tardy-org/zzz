pub fn handler(
    router: *const Router,
    secure: *Secsock,
    provision: *http.Server.Provision,
    rt: *zzz.tardy.Runtime,
) !http.Server.State {
    const routing = try router.routingInfo(
        rt.gpa,
        provision.request.uri.?,
        provision.captures,
        &provision.queries,
    );

    const handler_: Route.Handler.WithData = routing.route.handler(
        provision.request.method.?,
    ) orelse {
        provision.response.headers.clearRetainingCapacity();
        provision.response.status = .@"Method Not Allowed";
        provision.response.mime = .TEXT;
        provision.response.body = null;

        return .{ .next_respond = .responding };
    };

    const ctx: http.Context = .{
        .runtime = rt,
        .arena = provision.arena.allocator(),
        .header_writer = &provision.header_writer,
        .request = &provision.request,
        .response = &provision.response,
        .storage = &provision.storage,
        .tls = secure,
        .captures = routing.captures,
        .queries = routing.queries,
    };

    var next: Middleware.Next = .{
        .ctx = &ctx,
        .middlewares = handler_.middlewares,
        .handler = handler_,
    };

    const secure_info = secure.info();

    const respond: http.Respond = next.run() catch |err| respond: {
        log.err("rt{d} - \"{t} {s}\" {t} ({s})", .{
            rt.id,
            provision.request.method.?,
            provision.request.uri.?,
            err,
            secure_info.address,
        });

        // If in Debug Mode, we will return the error name. In other modes,
        // we won't to avoid leaking implemenation details.
        const body = if (comptime builtin.mode == .debug)
            @errorName(err)
        else
            "";

        break :respond try provision.response.apply(.{
            .status = .@"Internal Server Error",
            .mime = .TEXT,
            .body = body,
        });
    };

    return .{ .next_respond = respond };
}

pub fn next_response(
    respond: http.Respond,
    secure: *Secsock,
    provision: *http.Server.Provision,
    rt: *zzz.tardy.Runtime,
    keepalive_count: *u16,
    config: zzz.Config,
) !http.Server.State {
    switch (respond) {
        .responding => {
            try provision.response.writeHeaders(
                &provision.header_writer,
                if (provision.response.body) |body|
                    body.len
                else
                    null,
            );
            const headers = provision.header_writer.buffered();

            // TODO: lets use optional properly
            const body = provision.response.body orelse "";

            const recv_slice = try provision.zc_recv_buffer.get_write_area(
                rt.gpa,
                config.recv_buffer_size.Usize(),
            );
            const pseudo: zzz.core.Pseudoslice = .init(
                headers,
                body,
                recv_slice,
            );

            var sent: usize = 0;
            while (sent < pseudo.len) {
                const send_slice = pseudo.get(
                    sent,
                    sent + recv_slice.len,
                );

                const sent_length = secure.send_all(
                    rt,
                    send_slice,
                ) catch |err| {
                    log.err(
                        "respond: send failed on socket | {t}",
                        .{err},
                    );
                    return .{ .next_respond = .close };
                };
                defer sent += sent_length;

                if (sent_length != send_slice.len) return .{ .next_respond = .close };
            }

            return .{ .next_respond = .responded };
        },
        .responded => {
            const connection = provision.request.headers.get(
                "Connection",
            ) orelse "keep-alive";
            if (mem.eql(u8, connection, "close")) return .{
                .next_respond = .close,
            };

            if (config.keepalive_count_max) |max| {
                if (keepalive_count.* > max) {
                    log.debug(
                        "closing connection, exceeded keepalive max",
                        .{},
                    );
                    return .{ .next_respond = .close };
                }

                keepalive_count.* += 1;
            }

            return .{ .next_request = {} };
        },
        .close => return .{ .next_respond = .close },
    }
}

const std = @import("std");
const mem = std.mem;
const log = std.log.scoped(.@"server/handler");

const zzz = @import("zzz");
const http = zzz.http;
const Router = http.Router;
const Route = Router.Route;
const Middleware = Router.Middleware;
const Secsock = zzz.Secsock;
const builtin = @import("builtin");
