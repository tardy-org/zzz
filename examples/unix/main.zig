const Tardy = tardy.Tardy(.auto);

pub fn root(ctx: *const http.Context, _: void) !http.Respond {
    return ctx.response.apply(.{
        .status = .OK,
        .mime = .HTML,
        .body = "This is an HTTP benchmark\n",
    });
}

// Test With: curl --unix-socket /tmp/zzz.sock http://localhost/
pub fn main(init: std.process.Init) !void {
    const unix_path = "/tmp/zzz.sock";

    const sock: Secsock.Unix = .empty;
    const unix_sock = try sock.unix(init.gpa, unix_path);
    defer unix_sock.deinit(init.gpa);

    std.log.info("Socket {s}", .{unix_sock.info().address});

    var router: http.Router = try .init(init.gpa, &.{
        Route.init("/").get({}, root).layer(),
    }, .{});
    defer router.deinit(init.gpa);

    const EntryParams = struct {
        router: *const http.Router,
        unix: *const Secsock,
    };
    const params: EntryParams = .{
        .router = &router,
        .unix = &unix_sock,
    };

    var t: Tardy = try .init(init.gpa, init.io, .{
        .threading = .auto,
    });
    defer t.deinit();

    try t.entry(
        params,
        struct {
            fn entry(rt: *tardy.Runtime, p: EntryParams) !void {
                const server: http.Server = .init(.{
                    .stack_size = .KiB(45),
                });

                try server.serve(rt, p.router, p.unix);
                defer server.deinit();
            }
        }.entry,
    );
}

const log = std.log.scoped(.@"examples/unix");

const std = @import("std");

const zzz = @import("zzz");
const http = zzz.http;
const tardy = zzz.tardy;
const Secsock = zzz.Secsock;
const Route = http.Router.Route;
