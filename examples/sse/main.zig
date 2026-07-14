const std = @import("std");

const zzz = @import("zzz");
const http = zzz.http;
const tardy = zzz.tardy;
const Runtime = tardy.Runtime;
const Socket = tardy.net.Socket;
const Timer = Runtime.Timer;
const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;
const SSE = http.SSE;

const log = std.log.scoped(.@"examples/sse");

const Tardy = tardy.Tardy(.auto);

fn sse_handler(ctx: *const Context, _: void) !Respond {
    var sse: SSE = try .init(ctx);

    while (true) {
        sse.send(.{ .data = "hello from handler!" }) catch break;
        try Timer.delay(ctx.runtime, .{ .nanoseconds = 1 * std.time.ns_per_s });
    }

    return .responded;
}

pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var t: Tardy = try .init(init.gpa, init.io, .{ .threading = .single });
    defer t.deinit();

    const router: Router = try .init(init.gpa, &.{
        Route.init("/").embed_file(.{ .mime = .HTML }, @embedFile("./index.html")).layer(),
        Route.init("/stream").get({}, sse_handler).layer(),
    }, .{});

    // create socket for tardy
    var socket: Socket = try .init(init.io, .{
        .tcp = .{ .host = host, .port = port },
    });
    defer socket.close_blocking();

    try socket.bind();
    try socket.listen(256);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server: Server = .init(.{
                    .stack_size = .@"4MiB",
                    .socket_buffer_bytes = 1024 * 2,
                });
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
