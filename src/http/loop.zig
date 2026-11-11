pub fn request(
    rt: *zzz.tardy.Runtime,
    secure: *Secsock,
    provision: *http.Server.Provision,
    config: zzz.Config,
    kind: *http.Server.Request,
) !http.Server.State {
    switch (kind.*) {
        .header => {
            const recv_count = try http.recv_all(
                rt,
                secure,
                &provision.zc_recv_buffer,
                &config,
            );
            if (provision.zc_recv_buffer.len() > config.request_size_max.Usize())
                return .{ .respond = .close };

            const end_marker = "\r\n\r\n";
            const begin = provision.zc_recv_buffer.len() - recv_count;

            if (!mem.endsWith(u8, provision.zc_recv_buffer.subslice(.{
                .start = begin,
            }), end_marker)) {
                const respond = try provision.response.apply(.{
                    .status = .@"Bad Request",
                    .mime = .JSON,
                    // TODO: maybe rt should have an `arena` and `gpa`
                    .body = try rt.gpa.print("{f}", .{
                        std.json.fmt(
                            struct { msg: []const u8 }{
                                .msg = "Check if using https/http incorrectly in the request.",
                            },
                            .{},
                        ),
                    }),
                });
                return .{ .respond = respond };
            }

            const end = provision.zc_recv_buffer.len();

            try provision.request.parse(
                rt.gpa,
                provision.zc_recv_buffer.subslice(
                    .{ .end = end },
                ),
                .{
                    .request_bytes_max = config.request_size_max,
                    .request_uri_bytes_max = config.request_uri_size_max,
                },
            );

            const secure_info = secure.info();
            log.info("rt{d} - \"{t} {s}\" {s} ({s})", .{
                rt.id,
                provision.request.method.?,
                provision.request.uri.?,
                provision.request.headers.get("User-Agent") orelse "N/A",
                secure_info.address,
            });

            const content_length_str = provision.request.headers.get(
                "Content-Length",
            ) orelse {
                return .{ .handler = {} };
            };
            const content_length = try std.fmt.parseUnsigned(
                usize,
                content_length_str,
                10,
            );
            log.debug("content length={d}", .{content_length});

            if (provision.request.expect_body() and content_length != 0) return .{
                .request = .{
                    .body = .{
                        // TODO: this seems like a vestiage for the past
                        // investigate and remove it if found not useful
                        .current_length = provision.zc_recv_buffer.len() - end,
                        .content_length = content_length,
                    },
                },
            } else return .{ .handler = {} };
        },
        .body => |*info| {
            if (info.current_length == info.content_length) {
                provision.request.body = provision.zc_recv_buffer.subslice(
                    .{
                        .start = provision.zc_recv_buffer.len() - info.content_length,
                    },
                );

                return .{ .handler = {} };
            }

            const recv_slice = try provision.zc_recv_buffer.get_write_area(
                rt.gpa,
                config.recv_buffer_size.Usize(),
            );

            const recv_count = secure.recv(
                rt,
                recv_slice,
            ) catch |e| switch (e) {
                error.Closed => return .{ .respond = .close },
                else => |err| {
                    log.err("request=>body: recv failed on socket | {t}", .{err});
                    return .{ .respond = .close };
                },
            };
            provision.zc_recv_buffer.mark_written(recv_count);

            if (provision.zc_recv_buffer.len() > config.request_size_max.Usize())
                return .{ .respond = .close };

            info.current_length += recv_count;
            debug.assert(info.current_length <= info.content_length);

            return .{ .handler = {} };
        },
    }
}

pub fn handler(
    rt: *zzz.tardy.Runtime,
    router: *const Router,
    secure: *Secsock,
    provision: *http.Server.Provision,
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

        return .{ .respond = .responding };
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

    // Note that the request handler sets the `ctx.response` when run
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

    return .{ .respond = respond };
}

pub fn response(
    rt: *zzz.tardy.Runtime,
    secure: *Secsock,
    provision: *http.Server.Provision,
    config: zzz.Config,
    respond: http.Respond,
    keepalive_count: *u16,
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
                    return .{ .respond = .close };
                };
                defer sent += sent_length;

                if (sent_length != send_slice.len) return .{
                    .respond = .close,
                };
            }

            return .{ .respond = .responded };
        },
        .responded => {
            const connection = provision.request.headers.get(
                "Connection",
            ) orelse "keep-alive";
            if (mem.eql(u8, connection, "close")) return .{
                .respond = .close,
            };

            if (config.keepalive_count_max) |max| {
                if (keepalive_count.* > max) {
                    log.debug(
                        "closing connection, exceeded keepalive max",
                        .{},
                    );
                    return .{ .respond = .close };
                }

                keepalive_count.* += 1;
            }

            return .{ .next_request = {} };
        },
        .close => return .{ .respond = .close },
    }
}

const log = std.log.scoped(.@"server/handler");

const std = @import("std");
const mem = std.mem;
const debug = std.debug;
const builtin = @import("builtin");

const zzz = @import("zzz");
const http = zzz.http;
const Router = http.Router;
const Route = Router.Route;
const Middleware = Router.Middleware;
const Secsock = zzz.Secsock;
