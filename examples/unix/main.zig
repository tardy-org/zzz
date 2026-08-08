const Tardy = tardy.Tardy(.auto);
pub const std_options: std.Options = .{ .log_level = .err };

pub fn root(ctx: *const http.Context, _: void) !http.Respond {
    return ctx.response.apply(.{
        .status = .OK,
        .mime = .HTML,
        .body = "This is an HTTP benchmark\n",
    });
}

// Test With: curl --unix-socket /tmp/zzz.sock http://localhost/
pub fn main(init: std.process.Init) !void {
    var t: Tardy = try .init(init.gpa, init.io, .{ .threading = .auto });
    defer t.deinit();

    var router: http.Router = try .init(init.gpa, &.{
        Route.init("/").get({}, root).layer(),
    }, .{});
    defer router.deinit(init.gpa);

    var socket: net.Socket = try .init(init.io, .{
        .unix = "/tmp/zzz.sock",
    });
    defer socket.close_blocking();
    defer std.Io.Dir.deleteDirAbsolute(
        init.io,
        "/tmp/zzz.sock",
    ) catch unreachable;

    try socket.bind();
    try socket.listen(256);

    const EntryParams = struct {
        router: *const http.Router,
        unix: *const net.Socket,
    };
    const params: EntryParams = .{
        .router = &router,
        .unix = socket,
    };

    try t.entry(
        params,
        struct {
            fn entry(rt: *tardy.Runtime, p: EntryParams) !void {
                const server: http.Server = .init(.{});

                try server.serve(rt, p.router, .{ .normal = p.unix });
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
const net = tardy.net;
const Route = http.Router.Route;
