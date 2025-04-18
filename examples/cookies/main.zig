const std = @import("std");
const log = std.log.scoped(.@"examples/cookies");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Middleware = http.Middleware;
const Respond = http.Respond;
const Cookie = http.Cookie;

fn base_handler(ctx: *const Context, _: void) !Respond {
    var iter = ctx.request.cookies.iterator();
    while (iter.next()) |kv| log.debug("cookie: k={s} v={s}", .{ kv.key_ptr.*, kv.value_ptr.* });

    const cookie = Cookie.init("example_cookie", "abcdef123");
    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = "Hello, world!",
        .headers = &.{
            .{ "Set-Cookie", try cookie.to_string_alloc(ctx.allocator) },
        },
    });
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(allocator, .{ .threading = .single });
    defer t.deinit();

    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, base_handler).layer(),
    }, .{});
    defer router.deinit(allocator);

    // create socket for tardy
    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(4096);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server = Server.init(.{
                    .stack_size = 1024 * 1024 * 4,
                    .socket_buffer_bytes = 1024 * 2,
                    .keepalive_count_max = null,
                    .connection_count_max = 10,
                });
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
