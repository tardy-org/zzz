const Tardy = tardy.Tardy(.auto);

fn handler(ctx: *const http.Context, _: void) !http.Respond {
    const body =
        \\ <!DOCTYPE html>
        \\ <html>
        \\ <head>
        \\ <link rel="stylesheet" href="/embed/pico.min.css"/>
        \\ </head>
        \\ <body>
        \\ <h1>Hello, World!</h1>
        \\ </body>
        \\ </html>
    ;

    return ctx.response.apply(.{
        .status = .OK,
        .mime = .HTML,
        .body = body[0..],
    });
}

// Test with: https://localhost:9862/
pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var bearssl: Secsock.BearSSL = try .init(
        init.gpa,
        "CERTIFICATE",
        @embedFile("certs/cert.pem"),
        "EC PRIVATE KEY",
        @embedFile("certs/key.pem"),
    );
    defer bearssl.deinit(init.gpa);

    const tls = try bearssl.tls(init.gpa, .{
        .host = host,
        .port = port,
    });

    var router: http.Router = try .init(init.gpa, &.{
        Route.init("/").get({}, handler).layer(),
        middleware.Compression(.{ .gzip = .{} }),
        Route.init("/embed/pico.min.css").embed_file(
            .{ .mime = .CSS },
            @embedFile("embed/pico.min.css"),
        ).layer(),
    }, .{});
    defer router.deinit(init.gpa);

    const EntryParams = struct {
        router: *const http.Router,
        tls: *const Secsock,
    };
    const params: EntryParams = .{
        .router = &router,
        .tls = &tls,
    };

    var t: Tardy = try .init(init.gpa, init.io, .{
        .threading = .auto,
    });
    defer t.deinit();

    try t.entry(
        params,
        struct {
            fn entry(rt: *tardy.Runtime, p: EntryParams) !void {
                const server: http.Server = .init(.{ .stack_size = .max });

                try server.serve(rt, p.router, p.tls);
                defer server.deinit();
            }
        }.entry,
    );
}

const log = std.log.scoped(.@"examples/tls");

const std = @import("std");

const zzz = @import("zzz");
const http = zzz.http;
const tardy = zzz.tardy;
const Secsock = zzz.Secsock;
const middleware = http.middleware;
const Route = http.Router.Route;
