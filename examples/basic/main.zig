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

    const transport: Secsock.Unsecured = .empty;
    const tcp = try transport.tcp(init.gpa, .{
        .host = host,
        .port = port,
    });
    defer tcp.deinit(init.gpa);

    var router: http.Router = try .init(init.gpa, &.{
        Route.init("/").get({}, hello_world).layer(),
    }, .{});
    defer router.deinit(init.gpa);

    const EntryParams = struct {
        router: *const http.Router,
        tls: *const Secsock,
    };
    const params: EntryParams = .{
        .router = &router,
        .tls = &tcp,
    };

    var t: Tardy = try .init(init.gpa, init.io, .{
        .threading = .auto,
    });
    defer t.deinit();

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

                try server.serve(rt, p.router, p.tls);
                defer server.deinit();
            }
        }.entry,
    );
}

const log = std.log.scoped(.@"examples/basic");

const std = @import("std");

const zzz = @import("zzz");
const http = zzz.http;
const Secsock = zzz.Secsock;
const tardy = zzz.tardy;
const Route = http.Router.Route;
