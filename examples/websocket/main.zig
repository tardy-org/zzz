const Tardy = tardy.Tardy(.auto);

fn echo(ctx: *const http.Context, deps: void) !http.Respond {
    _ = deps;
    const req = ctx.websocket.?.request;

    switch (req.header.opcode) {
        // onClose
        .close => {
            return ctx.websocket.?.response.apply(.{
                .fin = req.header.fin,
                .opcode = req.header.opcode,
                .status = .@"Normal Closure",
                .message = @tagName(.@"Normal Closure"),
            });
        },
        // onMessage
        else => {
            return ctx.websocket.?.response.apply(.{
                .fin = req.header.fin,
                .opcode = req.header.opcode,
                .message = req.payload.data,
            });
        },
    }
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
        Route.init("/echo").get({}, echo).layer(),
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

const log = std.log.scoped(.@"examples/websocket");

const std = @import("std");

const zzz = @import("zzz");
const http = zzz.http;
const Secsock = zzz.Secsock;
const tardy = zzz.tardy;
const websocket = zzz.websocket;
const Route = http.Router.Route;
