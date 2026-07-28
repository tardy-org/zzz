const Tardy = tardy.Tardy(.auto);

fn hello_world(ctx: *const http.Context, _: void) !http.Respond {
    return ctx.response.apply(.{
        .status = .OK,
        .mime = .HTML,
        .body = "Hello, world!",
    });
}

pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var t: Tardy = try .init(init.gpa, init.io, .{
        .threading = .auto,
    });
    defer t.deinit();

    var router: http.Router = try .init(init.gpa, &.{
        Route.init("/").get({}, hello_world).layer(),
    }, .{});
    defer router.deinit(init.gpa);

    var socket: net.Socket = try .init(init.io, .{
        .tcp = .{ .host = host, .port = port },
    });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(4096);

    const EntryParams = struct {
        router: *const http.Router,
        socket: net.Socket,
    };
    const params: EntryParams = .{
        .router = &router,
        .socket = socket,
    };

    try t.entry(
        params,
        struct {
            fn entry(rt: *tardy.Runtime, p: EntryParams) !void {
                var server: http.Server = .init(.{
                    .stack_size = .@"64KiB",
                    .socket_buffer_bytes = 1024 * 2,
                    .keepalive_count_max = null,
                    .connection_count_max = 1024,
                });
                try server.serve(rt, p.router, .{
                    .normal = p.socket,
                });
            }
        }.entry,
    );
}

const log = std.log.scoped(.@"examples/basic");

const std = @import("std");

const zzz = @import("zzz");
const http = zzz.http;
const tardy = zzz.tardy;
const net = tardy.net;
const Route = http.Router.Route;
