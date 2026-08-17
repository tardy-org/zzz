pub const Server = @This();

config: Config,

pub fn init(config: Config) Server {
    return .{ .config = config };
}

pub fn deinit(_: *const Server) void {}

/// Serve an HTTP server.
pub fn serve(
    server: *const Server,
    rt: *Runtime,
    router: *const Router,
    tls: *const Secsock,
) !void {
    const tls_info = tls.info();
    log.info("security mode: {t}", .{tls_info.name});

    const count = server.config.max_connection_count orelse 1024;
    const pooling: pool.Kind = if (server.config.max_connection_count == null)
        .grow
    else
        .static;

    var arena_alloc: ArenaAllocator = .init(rt.gpa);
    defer arena_alloc.deinit();

    const arena = arena_alloc.allocator();

    const provision_pool = try arena.create(
        pool.Pool(Provision),
    );
    provision_pool.* = try .init(arena, count, pooling);
    errdefer arena.destroy(provision_pool);

    const connection_count = try arena.create(usize);
    errdefer arena.destroy(connection_count);
    connection_count.* = 0;

    const accept_queued = try arena.create(bool);
    errdefer arena.destroy(accept_queued);
    accept_queued.* = true;

    const pool_header_buffer: []u8 = try arena.alloc(
        u8,
        count * server.config.max_http_header_size.Usize(),
    );
    errdefer arena.free(pool_header_buffer);
    var next_header_buffer_index: usize = 0;

    // initialize first batch of provisions :)
    for (provision_pool.items) |*provision| {
        provision.initalized = true;
        provision.zc_recv_buffer = try .init(
            rt.gpa,
            server.config.socket_buffer_size.Usize(),
        );
        errdefer provision.zc_recv_buffer.deinit(arena);

        provision.header_writer = .fixed(
            pool_header_buffer[next_header_buffer_index..][0..server.config.max_http_header_size.Usize()],
        );
        next_header_buffer_index += server.config.max_http_header_size.Usize();

        provision.captures = try arena.alloc(
            Trie.Capture,
            server.config.max_capture_count,
        );
        errdefer arena.free(provision.captures);

        provision.queries = .empty;
        provision.storage = .empty;
        provision.request = .empty;
        provision.response = .empty;
    }

    try rt.spawn(
        mainLoop,
        .{
            rt,
            arena,
            server.config,
            router,
            tls,
            provision_pool,
            connection_count,
            accept_queued,
        },
        server.config.stack_size,
    );
}

pub fn mainLoop(
    rt: *Runtime,
    arena: *ArenaAllocator,
    config: Config,
    router: *const Router,
    tls: *const Secsock,
    provisions: *pool.Pool(Provision),
    connection_count: *usize,
    accept_queued: *bool,
) !void {
    accept_queued.* = false;
    var secure = tls.accept(rt) catch |e| {
        if (!accept_queued.*) {
            try rt.spawn(
                mainLoop,
                .{
                    rt,
                    arena,
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
        return e;
    };
    defer secure.deinit(rt.gpa);
    const secure_info = secure.info();

    connection_count.* += 1;
    defer connection_count.* -= 1;

    if (config.max_connection_count) |max| if (connection_count.* > max) {
        return log.debug("over connection max, closing", .{});
    };

    log.debug("queuing up a new accept request", .{});
    try rt.spawn(
        mainLoop,
        .{
            rt,
            arena,
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

    const index = try provisions.borrow(arena);
    defer provisions.release(index);
    const provision = provisions.get_ptr(index);

    // if we are growing, we can handle a newly allocated provision here.
    // otherwise, it should be initalized.
    if (!provision.initalized) {
        log.debug("initalizing new provision", .{});
        provision.zc_recv_buffer = try .init(
            arena,
            config.socket_buffer_size.Usize(),
        );
        errdefer provision.zc_recv_buffer.deinit(arena);

        // TODO: use a server config option
        provision.header_writer = .fixed(
            try provision.arena_state.allocator().alloc(u8, 8 * 1024),
        );
        provision.captures = try arena.alloc(
            Trie.Capture,
            config.max_capture_count,
        );
        errdefer arena.free(provision.captures);

        provision.queries = .empty;
        provision.storage = .empty;
        provision.request = .empty;
        provision.response = .empty;
        provision.initalized = true;
    }
    defer prepare_new_request(
        arena,
        null,
        provision,
        config,
    ) catch unreachable;

    var state: State = .{ .request = .header };

    provision.recv_slice = try provision.zc_recv_buffer.get_write_area(
        rt.gpa,
        config.socket_buffer_size.Usize(),
    );

    var keepalive_count: u16 = 0;

    http_loop: while (true) switch (state) {
        .request => |*kind| switch (kind.*) {
            .header => {
                const recv_count = secure.recv(
                    rt,
                    provision.recv_slice,
                ) catch |e|
                    switch (e) {
                        error.Closed => break,
                        else => |err| {
                            log.debug(
                                "recv failed on socket | {t}",
                                .{err},
                            );
                            break;
                        },
                    };

                provision.zc_recv_buffer.mark_written(recv_count);
                provision.recv_slice = try provision.zc_recv_buffer.get_write_area(
                    rt.gpa,
                    config.socket_buffer_size.Usize(),
                );
                if (provision.zc_recv_buffer.len > config.max_request_size.Usize())
                    break;

                const search_area_start =
                    (provision.zc_recv_buffer.len - recv_count) -| 4;

                if (mem.find(
                    u8,
                    // Minimize the search area.
                    provision.zc_recv_buffer.subslice(.{
                        .start = search_area_start,
                    }),
                    "\r\n\r\n",
                )) |header_end| {
                    const real_header_end = header_end + 4;
                    try provision.request.parse_headers(
                        // Add 4 to account for the actual header end sequence.
                        provision.zc_recv_buffer.subslice(
                            .{ .end = real_header_end },
                        ),
                        .{
                            .max_request_bytes = config.max_request_size,
                            .max_uri_bytes = config.max_request_uri_size,
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
                    ) orelse "0";
                    const content_length = try std.fmt.parseUnsigned(
                        usize,
                        content_length_str,
                        10,
                    );
                    log.debug("content length={d}", .{content_length});

                    if (provision.request.expect_body() and content_length != 0) {
                        state = .{
                            .request = .{
                                .body = .{
                                    .current_length = provision.zc_recv_buffer.len - real_header_end,
                                    .content_length = content_length,
                                },
                            },
                        };
                    } else state = .handler;
                }
            },
            .body => |*info| {
                if (info.current_length == info.content_length) {
                    provision.request.body = provision.zc_recv_buffer.subslice(
                        .{
                            .start = provision.zc_recv_buffer.len - info.content_length,
                        },
                    );
                    state = .handler;
                    continue;
                }

                const recv_count = secure.recv(
                    rt,
                    provision.recv_slice,
                ) catch |e|
                    switch (e) {
                        error.Closed => break,
                        else => |err| {
                            log.debug(
                                "recv failed on socket | {t}",
                                .{err},
                            );
                            break;
                        },
                    };

                provision.zc_recv_buffer.mark_written(recv_count);
                provision.recv_slice = try provision.zc_recv_buffer.get_write_area(
                    rt.gpa,
                    config.socket_buffer_size.Usize(),
                );
                if (provision.zc_recv_buffer.len > config.max_request_size.Usize())
                    break;

                info.current_length += recv_count;
                debug.assert(info.current_length <= info.content_length);
            },
        },
        .handler => {
            const found = try router.get_bundle_from_host(
                rt.gpa,
                provision.request.uri.?,
                provision.captures,
                &provision.queries,
            );
            defer rt.gpa.free(found.duped);
            defer for (found.duped) |dupe| rt.gpa.free(dupe);

            const h_with_data: Route.Handler.WithData = found.route.get_handler(
                provision.request.method.?,
            ) orelse {
                provision.response.headers.clearRetainingCapacity();
                provision.response.status = .@"Method Not Allowed";
                provision.response.mime = .TEXT;
                provision.response.body = null;

                state = .respond;
                continue;
            };

            const context: http.Context = .{
                .runtime = rt,
                .arena = arena.allocator(),
                .header_writer = &provision.header_writer,
                .request = &provision.request,
                .response = &provision.response,
                .storage = &provision.storage,
                .tls = &secure,
                .captures = found.captures,
                .queries = found.queries,
            };

            var next: Middleware.Next = .{
                .context = &context,
                .middlewares = h_with_data.middlewares,
                .handler = h_with_data,
            };

            const next_respond: http.Respond = next.run() catch |err| blk: {
                log.warn("rt{d} - \"{t} {s}\" {t} ({s})", .{
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

                break :blk try provision.response.apply(.{
                    .status = .@"Internal Server Error",
                    .mime = .TEXT,
                    .body = body,
                });
            };

            switch (next_respond) {
                .standard => {
                    // applies the respond onto the response
                    // try provision.response.apply(respond);
                    state = .respond;
                },
                .responded => {
                    const connection = provision.request.headers.get(
                        "Connection",
                    ) orelse "keep-alive";
                    if (mem.eql(u8, connection, "close")) break :http_loop;
                    if (config.max_keepalive_count) |max| {
                        if (keepalive_count > max) {
                            log.debug(
                                "closing connection, exceeded keepalive max",
                                .{},
                            );
                            break :http_loop;
                        }

                        keepalive_count += 1;
                    }

                    try prepare_new_request(
                        rt.gpa,
                        &state,
                        provision,
                        config,
                    );
                },
                .close => break :http_loop,
            }
        },
        .respond => {
            // TODO: lets use optional properly
            const body = provision.response.body orelse "";
            const content_length = body.len;

            try provision.response.headers_into_writer(
                &provision.header_writer,
                content_length,
            );
            const headers = provision.header_writer.buffered();

            var sent: usize = 0;
            const pseudo: zcore.Pseudoslice = .init(
                headers,
                body,
                provision.recv_slice,
            );

            while (sent < pseudo.len) {
                const send_slice = pseudo.get(
                    sent,
                    sent + provision.recv_slice.len,
                );

                const sent_length = secure.send_all(
                    rt,
                    send_slice,
                ) catch |err| {
                    log.debug("send failed on socket | {t}", .{err});
                    break;
                };
                if (sent_length != send_slice.len) break :http_loop;
                sent += sent_length;
            }

            const connection = provision.request.headers.get(
                "Connection",
            ) orelse "keep-alive";
            if (mem.eql(u8, connection, "close")) break;
            if (config.max_keepalive_count) |max| {
                if (keepalive_count > max) {
                    log.debug(
                        "closing connection, exceeded keepalive max",
                        .{},
                    );
                    break;
                }

                keepalive_count += 1;
            }

            try prepare_new_request(
                rt.gpa,
                &state,
                provision,
                config,
            );
        },
    };

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

fn prepare_new_request(
    arena: *ArenaAllocator,
    state: ?*State,
    provision: *Provision,
    config: Config,
) !void {
    debug.assert(provision.initalized);
    const alloc = arena.allocator();
    provision.request.clear(alloc);
    provision.response.clear();
    provision.storage.clear(alloc);
    provision.zc_recv_buffer.clear_retaining_capacity();
    _ = provision.header_writer.consumeAll();
    _ = alloc.reset(.{
        .retain_with_limit = config.retained_arena_bytes.Usize(),
    });
    provision.recv_slice = try provision.zc_recv_buffer.get_write_area(
        alloc,
        config.socket_buffer_size.Usize(),
    );

    if (state) |s| s.* = .{ .request = .header };
}

/// These are various general configuration
/// options that are important for the actual framework.
///
/// This includes various different options and limits
/// for interacting with the underlying network.
pub const Config = struct {
    /// Stack Size
    ///
    /// If you have a large number of middlewares or
    /// create a LOT of stack memory, you may want to increase this.
    ///
    /// P.S: A lot of functions in the standard library do end up allocating
    /// a lot on the stack (such as std.log).
    ///
    /// Default: 1MB
    stack_size: Coroutine.Stack = .@"1MiB",
    /// Use a Max Header Size of 8KiB same as Nginx, Tomcat and Httpd but
    /// consider making this configurable
    /// https://stackoverflow.com/questions/686217/maximum-on-http-header-values
    /// Default: 8KiB
    max_http_header_size: zcore.Size = .@"8KiB",
    /// Maximum size (in bytes) of the Request.
    ///
    /// Default: 2MiB
    max_request_size: zcore.Size = .@"2MiB",
    /// Maximum size (in bytes) of the Request URI.
    ///
    /// Default: 2KiB
    max_request_uri_size: zcore.Size = .@"2KiB",
    /// Number of Maximum Concurrent Connections.
    ///
    /// This is applied PER runtime.
    /// zzz will drop/close any connections greater
    /// than this.
    ///
    /// You can set this to `null` to have no maximum.
    ///
    /// Default: `null`
    max_connection_count: ?u32 = null,
    /// Maximum number of Captures in a Route
    ///
    /// Default: 8
    max_capture_count: u16 = 8,
    /// Number of times a Request-Response can happen with keep-alive.
    ///
    /// Setting this to `null` will set no limit.
    ///
    /// Default: `null`
    max_keepalive_count: ?u16 = null,
    /// Amount of allocated memory retained
    /// after an arena is cleared.
    ///
    /// A higher value will increase memory usage but
    /// should make allocators faster.
    ///
    /// A lower value will reduce memory usage but
    /// will make allocators slower.
    ///
    /// Default: 1MiB
    retained_arena_bytes: zcore.Size = .@"1MiB",
    /// Amount of space on the `recv_buffer` retained
    /// after every send.
    ///
    /// Default: 1MiB
    retained_recv_bytes: zcore.Size = .@"1MiB",
    /// Maximum size (in bytes) of the Recv buffer.
    /// This is mainly a concern when you are reading in
    /// large requests before responding.
    ///
    /// Default: 2MiB
    max_recv_buffer_size: zcore.Size = .@"2MiB",
    /// Size of the buffer (in bytes) used for
    /// interacting with the socket.
    ///
    /// Default: 1 MiB
    socket_buffer_size: zcore.Size = .@"1MiB",
};

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
};

pub const Provision = struct {
    // TODO: store this bool out of band
    initalized: bool = false,
    recv_slice: []u8,
    zc_recv_buffer: ZeroCopy(u8),
    header_writer: Io.Writer,
    storage: zcore.Storage,
    captures: []Trie.Capture,
    queries: string_map.AnyCase,
    request: http.Request,
    response: http.Response,
};

const log = std.log.scoped(.@"zzz/http/Server");

const std = @import("std");
const mem = std.mem;
const ArenaAllocator = std.heap.ArenaAllocator;
const debug = std.debug;
const Io = std.Io;
const builtin = @import("builtin");
const tag = builtin.os.tag;

const zzz = @import("../root.zig");
const zcore = zzz.core;
const string_map = zcore.string_map;
const tardy = zzz.tardy;
const Coroutine = tardy.Coroutine;
const tcore = tardy.core;
const ZeroCopy = tcore.ZeroCopy;
const cross = tardy.cross;
const pool = tcore.pool;
const Runtime = tardy.Runtime;
const Secsock = zzz.Secsock;
const Socket = tardy.net.Socket;
const Task = Runtime.Task;
const http = zzz.http;
const Router = @import("Router.zig");
const Route = Router.Route;
const Middleware = Router.Middleware;
const Trie = Router.Trie;
