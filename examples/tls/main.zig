const std = @import("std");

const zzz = @import("zzz");
const http = zzz.HTTP;
const tardy = zzz.tardy;
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;
const Server = http.Server;
const Context = http.Context;
const Route = http.Route;
const Router = http.Router;
const Respond = http.Respond;
const secsock = zzz.secsock;
const SecureSocket = secsock.SecureSocket;
const Compression = http.Middlewares.Compression;

const log = std.log.scoped(.@"examples/tls");

const Tardy = tardy.Tardy(.auto);

fn root_handler(ctx: *const Context, _: void) !Respond {
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
        .mime = http.Mime.HTML,
        .body = body[0..],
    });
}

pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var t: Tardy = try .init(init.gpa, init.io, .{ .threading = .auto });
    defer t.deinit();

    var router: Router = try .init(init.gpa, &.{
        Route.init("/").get({}, root_handler).layer(),
        Compression(.{ .gzip = .{} }),
        Route.init("/embed/pico.min.css").embed_file(
            .{ .mime = .CSS },
            @embedFile("embed/pico.min.css"),
        ).layer(),
    }, .{});
    defer router.deinit(init.gpa);

    // create socket for tardy
    var socket: Socket = try .init(init.io, .{ .tcp = .{ .host = host, .port = port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(1024);

    var bearssl: secsock.BearSSL = .init(init.gpa);
    defer bearssl.deinit();
    try bearssl.add_cert_chain(
        "CERTIFICATE",
        @embedFile("certs/cert.pem"),
        "EC PRIVATE KEY",
        @embedFile("certs/key.pem"),
    );
    const secure = try bearssl.to_secure_socket(socket, .server);

    const EntryParams = struct {
        router: *const Router,
        socket: SecureSocket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = secure },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server: Server = .init(.{ .stack_size = 1024 * 1024 * 8 });
                try server.serve(rt, p.router, .{ .secure = p.socket });
            }
        }.entry,
    );
}
