const Tardy = tardy.Tardy(.auto);

const log = std.log.scoped(.@"examples/websocket");

pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    const transport: Secsock.Unsecured = .empty;
    const tcp = try transport.tcp(init.gpa, .{
        .host = host,
        .port = port,
    });
    defer tcp.deinit(init.gpa);

    var router: http.Router = try .init(init.gpa, &.{}, .{});
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
        &params,
        struct {
            fn entry(rt: *tardy.Runtime, p: *const EntryParams) !void {
                var ws: websocket.Server = .init(.{
                    .stack_size = .KiB(64),
                    .recv_buffer_size = .@"2KiB",
                    .keepalive_count_max = null,
                    .connection_count_max = 64,
                });

                try ws.serve(rt, p.router, p.tls);
            }
        }.entry,
    );
}

const std = @import("std");
const zzz = @import("zzz");
const http = zzz.http;
const Secsock = zzz.Secsock;
const tardy = zzz.tardy;
const websocket = zzz.websocket;
const Route = http.Router.Route;
