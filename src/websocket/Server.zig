pub const Server = @This();

config: zzz.Config,

pub fn init(config: zzz.Config) Server {
    const recv_buffer_size = config.recv_buffer_size.Usize();
    const recv_zerocopy_size = config.recv_zerocopy_size.Usize();
    debug.assert(recv_zerocopy_size >= recv_buffer_size * 3);

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
            state = try loop.handshake(
                rt,
                &secure,
                provision,
                config,
            );
            continue :ws_loop state;
        },
        .handler => {
            const frame = request.start(
                &secure,
                rt,
                &provision.zc_recv_buffer,
                config,
            );
            provision.request = frame;

            state = try loop.handler(
                rt,
                router,
                &secure,
                provision,
            );
            continue :ws_loop state;
        },
        .respond => |respond| {
            state = try loop.response(
                rt,
                &secure,
                provision,
                config,
                respond,
            );
            switch (respond) {
                .close => break :ws_loop,
                else => continue :ws_loop state,
            }
        },
        .communication => {
            const frame = request.next(
                &secure,
                rt,
                &provision.zc_recv_buffer,
                config,
            ) orelse break :ws_loop;

            provision.request = frame;
            state = try loop.handler(
                rt,
                router,
                &secure,
                provision,
            );
            continue :ws_loop state;
        },
        // TODO: how show I handle .next_request
        .next_request => {
            clearProvision(rt.gpa, provision, config);

            state = .handshake;
            continue :ws_loop state;
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

    provision.protocals = .empty;
    provision.extensions = .empty;

    provision.request = .empty;
    provision.response = .empty;

    // TODO: dupe needed data so `handshake` isn't keep around
    provision.handshake.request = try .init(
        gpa,
        config.header_fields_count_max,
    );
    errdefer provision.handshake.request.deinit(gpa);

    provision.handshake.response = try .init(
        gpa,
        config.header_fields_count_max,
    );
    errdefer provision.handshake.response.deinit(gpa);

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
    provision.handshake.request.clear(gpa);
    provision.handshake.response.clear();
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

pub const State = union(enum) {
    handshake,
    handler,
    // two-way communication channel
    communication: Communication,
    respond: http.Respond,
    next_request,
};

const Communication = union(enum) {
    receive,
    ping: Frame,
    pong: Frame,
    text: Frame,
    binary: Frame,
    fragment: Frame,
    close: Frame,
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
    handshake: struct {
        request: http.Request,
        response: http.Response,
    },
    request: Frame,
    response: Frame,
    /// ordered set of acceptable subprotocol by preference from client
    protocals: Set,
    /// ordered set of extensions
    extensions: Set,

    const Set = std.StringArrayHashMapUnmanaged(void);
};

const endian = builtin.target.cpu.arch.endian();
const log = std.log.scoped(.@"zzz/websocket/Server");

const std = @import("std");
const mem = std.mem;
const math = std.math;
const heap = std.heap;
const ascii = std.ascii;
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

const Frame = @import("Frame.zig");
const loop = @import("loop.zig");
const request = @import("request.zig");
