const std = @import("std");

const zzz = @import("zzz");
const http = zzz.http;
const tardy = zzz.tardy;
const Runtime = tardy.Runtime;
const Socket = tardy.net.Socket;
const Dir = tardy.fs.Dir;
const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;
const FsDir = http.FsDir;
const Compression = http.Middlewares.Compression;

const log = std.log.scoped(.@"examples/fs");

const Tardy = tardy.Tardy(.auto);

fn base_handler(ctx: *const Context, _: void) !Respond {
    const body =
        \\ <!DOCTYPE html>
        \\ <html>
        \\ <body>
        \\ <h1>Hello, World!</h1>
        \\ </body>
        \\ </html>
    ;

    return try ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body[0..],
    });
}

// Test With: http://localhost:9862/index.html
pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var t: Tardy = try .init(init.gpa, init.io, .{ .threading = .auto });
    defer t.deinit();

    const static_dir: Dir = .from_std(try std.Io.Dir.cwd().openDir(
        init.io,
        "examples/fs/static",
        .{},
    ));

    var router: Router = try .init(init.gpa, &.{
        Compression(.{ .gzip = .{} }),
        Route.init("/").get({}, base_handler).layer(),
        FsDir.serve("/", static_dir),
    }, .{});
    defer router.deinit(init.gpa);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    var socket: Socket = try .init(
        init.io,
        .{ .tcp = .{ .host = host, .port = port } },
    );
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(256);

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server: Server = .init(.{
                    .stack_size = .@"4MiB",
                    .socket_buffer_bytes = 1024 * 4,
                });
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
