pub const Server = @This();

config: zzz.Config,

pub fn init(config: zzz.Config) Server {
    const recv_buffer_size = config.recv_buffer_size.Usize();
    const recv_zerocopy_size = config.recv_zerocopy_size.Usize();
    debug.assert(recv_buffer_size < recv_zerocopy_size);
    debug.assert(recv_zerocopy_size % recv_buffer_size == 0);

    return .{ .config = config };
}

fn deinit(_: *const Server) void {}

/// Serve a WebSocket connection.
pub fn serve(
    ws: *const Server,
    rt: *Runtime,
    router: *const Router,
    tls: *const Secsock,
) !void {
    const tls_info = tls.info();
    log.info("security mode: {t}", .{tls_info.name});

    const count: u32, const pooling: pool.Kind =
        if (ws.config.connection_count_max) |count|
            .{ count, .static }
        else
            .{ 1024, .grow };

    const provision_pool = try rt.gpa.create(
        pool.Pool(Provision),
    );
    provision_pool.* = try .init(rt.gpa, count, pooling);
    errdefer rt.gpa.destroy(provision_pool);

    const connection_count = try rt.gpa.create(usize);
    errdefer rt.gpa.destroy(connection_count);
    connection_count.* = 0;

    const accept_queued = try rt.gpa.create(bool);
    errdefer rt.gpa.destroy(accept_queued);
    accept_queued.* = true;

    // initialize first batch of provisions :)
    for (provision_pool.items) |*provision|
        try initProvision(rt.gpa, provision, ws.config);

    try rt.spawn(
        mainLoop,
        .{
            rt,
            ws.config,
            router,
            tls,
            provision_pool,
            connection_count,
            accept_queued,
        },
        ws.config.stack_size,
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

    var state: State = .handshake;
    ws_loop: switch (state) {
        .handshake => {
            const recv_slice = try provision.zc_recv_buffer.get_write_area(
                rt.gpa,
                config.recv_buffer_size.Usize(),
            );

            const recv_count = secure.recv(
                rt,
                recv_slice,
            ) catch |e|
                switch (e) {
                    error.Closed => break :ws_loop,
                    else => |err| {
                        log.err(
                            "handshake recv failed on socket | {t}",
                            .{err},
                        );
                        break :ws_loop;
                    },
                };

            provision.zc_recv_buffer.mark_written(recv_count);
            if (provision.zc_recv_buffer.len > config.request_size_max.Usize())
                break :ws_loop;

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
                continue :ws_loop state;
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

            debug.assert(mem.findScalar(
                u8,
                provision.request.uri.?,
                '#',
            ) == null);

            debug.assert(provision.request.method.? == .GET);
            debug.assert(mem.eql(
                u8,
                provision.request.headers.get("Upgrade").?,
                "websocket",
            ));
            debug.assert(mem.eql(
                u8,
                provision.request.headers.get("Connection").?,
                "Upgrade",
            ));
            debug.assert(std.fmt.parseInt(
                u32,
                provision.request.headers.get("Sec-WebSocket-Version").?,
                10,
            ) catch unreachable == protocal_version);

            if (provision.request.headers.get(
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

            if (provision.request.headers.get(
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

            log.info("rt{d} - '{t} {s}' - {s} - ({s})", .{
                rt.id,
                provision.request.method.?,
                provision.request.uri.?,
                provision.request.headers.get("User-Agent") orelse "N/A",
                secure_info.address,
            });

            // Prepare Server Responses
            provision.response.status = .@"Switching Protocols";
            provision.response.headers.putAssumeCapacityNoClobber(
                "Upgrade",
                provision.request.headers.get("Upgrade").?,
            );
            provision.response.headers.putAssumeCapacityNoClobber(
                "Connection",
                provision.request.headers.get("Connection").?,
            );

            // TODO: protocal selection should be based on the servers support
            if (provision.protocals.count() != 0)
                provision.response.headers.putAssumeCapacityNoClobber(
                    "Sec-WebSocket-Protocol",
                    provision.protocals.keys()[0],
                );

            const handshake_accept_key = handshake.acceptKey(
                rt.gpa,
                provision.request.headers.get("Sec-WebSocket-Key").?,
            );

            provision.response.headers.putAssumeCapacityNoClobber(
                "Sec-WebSocket-Accept",
                handshake_accept_key[0..],
            );

            try provision.response.writeHeaders(
                &provision.header_writer,
                null,
            );
            const headers = provision.header_writer.buffered();

            const sent_length = secure.send_all(
                rt,
                headers,
            ) catch |err| {
                log.err("handshake: send failed on socket | {t}", .{err});
                break :ws_loop;
            };
            if (sent_length != headers.len) break :ws_loop;

            state = .handler;
            continue :ws_loop state;
        },
        else => {},
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

    provision.protocals = .empty;
    provision.extensions = .empty;

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
    provision.storage.clear(gpa);
    provision.protocals.clearRetainingCapacity();
    provision.extensions.clearRetainingCapacity();
    provision.zc_recv_buffer.clear_retaining_capacity();
    _ = provision.header_writer.consumeAll();
    _ = provision.arena.reset(if (config.arena_bytes_retained) |bytes_retained|
        .{ .retain_with_limit = bytes_retained.Usize() }
    else
        .{ .retain_capacity = {} });
}

const State = union(enum) {
    handshake,
    handler,
    // two-way communication channel
    communication,
    close,
};

pub const Provision = struct {
    // TODO: store this bool out of band
    initalized: bool = false,
    recv_slice: []u8,
    zc_recv_buffer: ZeroCopy(u8),
    header_writer: Io.Writer,
    arena: heap.ArenaAllocator,
    captures: []Trie.Capture,
    storage: zcore.Storage,
    queries: http.Queries,
    request: http.Request,
    response: http.Response,
    /// ordered set of acceptable subprotocol
    /// by preference from client
    protocals: Set,
    /// ordered set of extensions
    extensions: Set,

    const Set = std.StringArrayHashMapUnmanaged(void);
};

/// WebSocket protocal version
const protocal_version = 13;

const log = std.log.scoped(.@"zzz/websocket/Server");

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

const handshake = @import("handshake.zig");
const Frame = @import("Frame.zig");
