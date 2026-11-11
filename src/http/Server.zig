pub const Server = @This();

config: zzz.Config,

pub fn init(config: zzz.Config) Server {
    const recv_buffer_size = config.recv_buffer_size.Usize();
    const recv_zerocopy_size = config.recv_zerocopy_size.Usize();
    debug.assert(recv_zerocopy_size >= recv_buffer_size * 3);

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
        .request => |*kind| {
            state = try loop.request(
                kind,
                &secure,
                provision,
                rt,
                config,
            );
            continue :http_loop state;
        },
        .handler => {
            state = try loop.handler(
                router,
                &secure,
                provision,
                rt,
            );
            continue :http_loop state;
        },
        .next_respond => |next_respond| {
            state = try loop.next_response(
                next_respond,
                &secure,
                provision,
                rt,
                &keepalive_count,
                config,
            );
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

pub const Request = union(enum) {
    header,
    body: Body,

    const Body = struct {
        content_length: usize,
        current_length: usize,
    };
};

pub const State = union(enum) {
    request: Request,
    handler,
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

const loop = @import("loop.zig");
