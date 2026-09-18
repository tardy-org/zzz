pub const Server = @This();

config: zzz.Config,

pub fn init(config: zzz.Config) Server {
    return .{ .config = config };
}

fn deinit(gpa: mem.Allocator, provisions: *pool.Pool(Provision)) void {
    for (provisions.items) |*provision| {
        provision.initalized = false;

        provision.queries.deinit(gpa);
        provision.storage.deinit(gpa);
        provision.request.deinit(gpa);
        provision.response.deinit(gpa);

        provision.zc_recv_buffer.deinit(gpa);

        gpa.free(provision.header_writer.buffer);

        gpa.free(provision.captures);

        provision.arena.deinit();
    }
    provisions.deinit(gpa);
    gpa.destroy(provisions);
}

/// Serve an HTTP server.
pub fn serve(
    server: *const Server,
    rt: *Runtime,
    router: *const Router,
    tls: *const Secsock,
) !void {
    const tls_info = tls.info();
    log.info("security mode: {t}", .{tls_info.name});

    const provisions = try rt.gpa.create(
        pool.Pool(Provision),
    );
    errdefer rt.gpa.destroy(provisions);

    const count: u32, const pooling: pool.Kind =
        if (server.config.connection_count_max) |count|
            .{ count, .static }
        else
            .{ 256, .grow };

    provisions.* = try .init(rt.gpa, count, pooling);
    errdefer provisions.deinit(rt.gpa);

    // initialize first batch of provisions :)
    for (provisions.items) |*provision|
        try initProvision(rt.gpa, provision, server.config);

    const connection_count = try rt.gpa.create(usize);
    errdefer rt.gpa.destroy(connection_count);
    connection_count.* = 0;

    const accept_queued = try rt.gpa.create(bool);
    errdefer rt.gpa.destroy(accept_queued);
    accept_queued.* = true;

    try rt.spawn(
        mainLoop,
        .{
            rt,
            server.config,
            router,
            tls,
            provisions,
            connection_count,
            accept_queued,
        },
        server.config.stack_size,
    );
}

pub fn mainLoop(
    rt: *Runtime,
    config: zzz.Config,
    router: *const Router,
    tls: *const Secsock,
    provisions: *pool.Pool(Provision),
    connection_count: *usize,
    accept_queued: *bool,
) !void {
    accept_queued.* = false;
    var secure = tls.accept(rt) catch |err| {
        if (!accept_queued.*) {
            try rt.spawn(
                mainLoop,
                .{
                    rt,
                    config,
                    router,
                    tls,
                    provisions,
                    connection_count,
                    accept_queued,
                },
                config.stack_size,
            );
            accept_queued.* = true;
        }
        return err;
    };
    defer secure.deinit(rt.gpa);
    const secure_info = secure.info();

    connection_count.* += 1;
    defer connection_count.* -= 1;

    if (config.connection_count_max) |max| if (connection_count.* > max) {
        return log.debug("over connection max, closing", .{});
    };

    log.debug("queuing up a new accept request", .{});
    try rt.spawn(
        mainLoop,
        .{
            rt,
            config,
            router,
            tls,
            provisions,
            connection_count,
            accept_queued,
        },
        config.stack_size,
    );
    accept_queued.* = true;

    const index = try provisions.borrow(rt.gpa);
    defer provisions.release(index);
    const provision = provisions.get_ptr(index);

    // if we are growing, we can handle a newly allocated provision here.
    // otherwise, it should be initalized.
    if (!provision.initalized) {
        log.debug("initalizing new provision", .{});
        try initProvision(rt.gpa, provision, config);
    }
    defer clearProvision(rt.gpa, provision, config);

    var keepalive_count: u16 = 0;
    var state: State = .{ .request = .header };

    http_loop: switch (state) {
        .request => |*kind| switch (kind.*) {
            .header => {
                const recv_slice = try provision.zc_recv_buffer.get_write_area(
                    rt.gpa,
                    config.recv_buffer_size.Usize(),
                );
                const recv_count = secure.recv(
                    rt,
                    recv_slice,
                ) catch |e|
                    switch (e) {
                        error.Closed => break :http_loop,
                        else => |err| {
                            log.err(
                                "request=>header: recv failed on socket | {t}",
                                .{err},
                            );
                            break :http_loop;
                        },
                    };

                provision.zc_recv_buffer.mark_written(recv_count);
                if (provision.zc_recv_buffer.len > config.request_size_max.Usize())
                    break :http_loop;

                const begin = provision.zc_recv_buffer.len - recv_count;

                const end_marker = "\r\n\r\n";
                if (!mem.endsWith(u8, provision.zc_recv_buffer.subslice(.{
                    .start = begin,
                }), end_marker)) {
                    const respond = try provision.response.apply(.{
                        .status = .@"Bad Request",
                        .mime = .TEXT,
                        .body = "Check if using https/http incorrectly in the request.\n",
                    });
                    state = .{ .next_respond = respond };
                    continue :http_loop state;
                }

                const end = provision.zc_recv_buffer.len;

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
                    state = .handler;
                    continue :http_loop state;
                };
                const content_length = try std.fmt.parseUnsigned(
                    usize,
                    content_length_str,
                    10,
                );
                log.debug("content length={d}", .{content_length});

                if (provision.request.expect_body() and content_length != 0) state = .{
                    .request = .{
                        .body = .{
                            // TODO: this seems like a vestiage for the past
                            // investigate and remove it if found not useful
                            .current_length = provision.zc_recv_buffer.len - end,
                            .content_length = content_length,
                        },
                    },
                } else state = .handler;
                continue :http_loop state;
            },
            .body => |*info| {
                if (info.current_length == info.content_length) {
                    provision.request.body = provision.zc_recv_buffer.subslice(
                        .{
                            .start = provision.zc_recv_buffer.len - info.content_length,
                        },
                    );

                    state = .handler;
                    continue :http_loop state;
                }

                const recv_slice = try provision.zc_recv_buffer.get_write_area(
                    rt.gpa,
                    config.recv_buffer_size.Usize(),
                );

                const recv_count = secure.recv(
                    rt,
                    recv_slice,
                ) catch |e| switch (e) {
                    error.Closed => break :http_loop,
                    else => |err| {
                        log.err("request=>body: recv failed on socket | {t}", .{err});
                        break :http_loop;
                    },
                };

                provision.zc_recv_buffer.mark_written(recv_count);
                if (provision.zc_recv_buffer.len > config.request_size_max.Usize())
                    break :http_loop;

                info.current_length += recv_count;
                debug.assert(info.current_length <= info.content_length);

                state = .handler;
                continue :http_loop state;
            },
        },
        .handler => {
            const found = try router.get_bundle_from_host(
                rt.gpa,
                provision.request.uri.?,
                provision.captures,
                &provision.queries,
            );

            const h_with_data: Route.Handler.WithData = found.route.handler(
                provision.request.method.?,
            ) orelse {
                provision.response.headers.clearRetainingCapacity();
                provision.response.status = .@"Method Not Allowed";
                provision.response.mime = .TEXT;
                provision.response.body = null;

                state = .respond;
                continue :http_loop state;
            };

            const ctx: http.Context = .{
                .runtime = rt,
                .arena = provision.arena.allocator(),
                .header_writer = &provision.header_writer,
                .request = &provision.request,
                .response = &provision.response,
                .storage = &provision.storage,
                .tls = &secure,
                .captures = found.captures,
                .queries = found.queries,
            };

            var next: Middleware.Next = .{
                .ctx = &ctx,
                .middlewares = h_with_data.middlewares,
                .handler = h_with_data,
            };

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

            state = .{ .next_respond = respond };
            continue :http_loop state;
        },
        .next_respond => |next_respond| {
            switch (next_respond) {
                .standard => {
                    state = .respond;
                    continue :http_loop state;
                },
                .responded => {
                    const connection = provision.request.headers.get(
                        "Connection",
                    ) orelse "keep-alive";
                    if (mem.eql(u8, connection, "close")) break :http_loop;
                    if (config.keepalive_count_max) |max| {
                        if (keepalive_count > max) {
                            log.debug(
                                "closing connection, exceeded keepalive max",
                                .{},
                            );
                            break :http_loop;
                        }

                        keepalive_count += 1;
                    }

                    state = .next_request;
                    continue :http_loop state;
                },
                .close => break :http_loop,
            }
        },
        .respond => {
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
            const pseudo: zcore.Pseudoslice = .init(
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
                    break :http_loop;
                };
                defer sent += sent_length;

                if (sent_length != send_slice.len) break :http_loop;
            }

            state = .{ .next_respond = .responded };
            continue :http_loop state;
        },
        .next_request => {
            clearProvision(rt.gpa, provision, config);

            state = .{ .request = .header };
            continue :http_loop state;
        },
    }

    log.info("connection ({s}) closed", .{secure_info.address});

    if (!accept_queued.*) {
        try rt.spawn(
            mainLoop,
            .{
                rt,
                config,
                router,
                tls,
                provisions,
                connection_count,
                accept_queued,
            },
            config.stack_size,
        );
        accept_queued.* = true;
    }
}

fn initProvision(
    gpa: mem.Allocator,
    provision: *Provision,
    config: zzz.Config,
) !void {
    provision.initalized = true;

    provision.queries = .empty;
    provision.storage = .empty;

    provision.request = try .init(
        gpa,
        config.header_fields_count_max,
    );
    errdefer provision.request.deinit(gpa);

    provision.response = try .init(
        gpa,
        config.header_fields_count_max,
    );
    errdefer provision.response.deinit(gpa);

    provision.zc_recv_buffer = try .init(
        gpa,
        config.recv_zerocopy_size.Usize(),
    );
    errdefer provision.zc_recv_buffer.deinit(gpa);

    const header_buf = try gpa.alloc(
        u8,
        config.header_size_max.Usize(),
    );
    errdefer gpa.free(header_buf);
    provision.header_writer = .fixed(header_buf);

    provision.captures = try gpa.alloc(
        Trie.Capture,
        config.capture_count_max,
    );
    errdefer gpa.free(provision.captures);

    provision.arena = .init(gpa);
}

fn clearProvision(gpa: mem.Allocator, provision: *Provision, config: zzz.Config) void {
    debug.assert(provision.initalized);
    provision.request.clear(gpa);
    provision.response.clear();
    provision.queries.clear(gpa);
    provision.storage.clear(gpa);
    provision.zc_recv_buffer.clear_retaining_capacity();
    _ = provision.header_writer.consumeAll();
    _ = provision.arena.reset(if (config.arena_bytes_retained) |bytes_retained|
        .{ .retain_with_limit = bytes_retained.Usize() }
    else
        .{ .retain_capacity = {} });
}

const Request = union(enum) {
    header,
    body: Body,

    const Body = struct {
        content_length: usize,
        current_length: usize,
    };
};

const State = union(enum) {
    request: Request,
    handler,
    respond,
    next_request,
    next_respond: http.Respond,
};

pub const Provision = struct {
    // TODO: store this bool out of band
    initalized: bool = false,
    zc_recv_buffer: ZeroCopy(u8),
    header_writer: Io.Writer,
    arena: heap.ArenaAllocator,
    storage: zcore.Storage,
    captures: []Trie.Capture,
    queries: http.Queries,
    request: http.Request,
    response: http.Response,
};

const log = std.log.scoped(.@"zzz/http/Server");

const std = @import("std");
const mem = std.mem;
const heap = std.heap;
const debug = std.debug;
const Io = std.Io;
const builtin = @import("builtin");

const zzz = @import("zzz");
const zcore = zzz.core;
const tardy = zzz.tardy;
const Coroutine = tardy.Coroutine;
const tcore = tardy.core;
const ZeroCopy = tcore.ZeroCopy;
const pool = tcore.pool;
const Runtime = tardy.Runtime;
const Secsock = zzz.Secsock;
const Socket = tardy.net.Socket;
const Task = Runtime.Task;
const http = zzz.http;
const Router = http.Router;
const Route = Router.Route;
const Middleware = Router.Middleware;
const Trie = Router.Trie;
