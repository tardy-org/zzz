const Tardy = tardy.Tardy(.auto);

fn homePage(ctx: *const http.Context, _: void) !http.Respond {
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
        .mime = .HTML,
        .body = body[0..],
    });
}

// Test With: http://localhost:9862/index.html
pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    const transport: Secsock.Unsecured = .empty;
    const tcp = try transport.tcp(init.gpa, .{
        .host = host,
        .port = port,
    });
    defer tcp.deinit(init.gpa);

    const static_dir: fs.Dir = .from_std(try Io.Dir.cwd().openDir(
        init.io,
        "examples/fs/static",
        .{},
    ));

    var router: http.Router = try .init(init.gpa, &.{
        middleware.Compression(.{ .gzip = .{} }),
        Route.init("/").get({}, homePage).layer(),
        FsDir.serve("/", static_dir),
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
                    .stack_size = .@"2MiB",
                    .socket_buffer_bytes = 1024 * 4,
                });

                try server.serve(rt, p.router, p.tls);
                defer server.deinit();
            }
        }.entry,
    );
}

const log = std.log.scoped(.@"examples/fs");

const std = @import("std");
const Io = std.Io;

const zzz = @import("zzz");
const http = zzz.http;
const tardy = zzz.tardy;
const fs = tardy.fs;
const middleware = http.middleware;
const Route = http.Router.Route;
const FsDir = http.Router.FsDir;
const Secsock = zzz.Secsock;
