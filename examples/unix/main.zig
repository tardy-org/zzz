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

const log = std.log.scoped(.@"examples/benchmark");

const Tardy = tardy.Tardy(.auto);
pub const std_options: std.Options = .{ .log_level = .err };

pub fn root_handler(ctx: *const Context, _: void) !Respond {
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

    var router: Router = try .init(init.gpa, &.{
        Route.init("/").get({}, root_handler).layer(),
    }, .{});
    defer router.deinit(init.gpa);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    var socket: Socket = try .init(init.io, .{ .unix = "/tmp/zzz.sock" });
    defer std.Io.Dir.deleteDirAbsolute(init.io, "/tmp/zzz.sock") catch unreachable;
    defer socket.close_blocking();

    try socket.bind();
    try socket.listen(256);

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server: Server = .init(.{});
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
