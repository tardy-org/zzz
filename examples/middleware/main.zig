const std = @import("std");

const zzz = @import("zzz");
const http = zzz.http;
const tardy = zzz.tardy;
const Runtime = tardy.Runtime;
const Socket = tardy.net.Socket;
const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Next = http.Next;
const Respond = http.Respond;
const Middleware = http.Middleware;

const log = std.log.scoped(.@"examples/middleware");

const Tardy = tardy.Tardy(.auto);

fn root_handler(ctx: *const Context, id: i8) !Respond {
    const body_fmt =
        \\ <!DOCTYPE html>
        \\ <html>
        \\ <body>
        \\ <h1>Hello, World!</h1>
        \\ <p>id: {d}</p>
        \\ <p>stored: {d}</p>
        \\ </body>
        \\ </html>
    ;
    const body = try std.fmt.allocPrint(
        ctx.allocator,
        body_fmt,
        .{ id, ctx.storage.get(usize).? },
    );

    // This is the standard response and what you
    // will usually be using. This will send to the
    // client and then continue to await more requests.
    return ctx.response.apply(.{
        .status = .OK,
        .mime = .HTML,
        .body = body[0..],
    });
}

fn passing_middleware(next: *Next, _: void) !Respond {
    log.info("pass middleware: {s}", .{next.context.request.uri.?});
    try next.context.storage.put(usize, 100);
    return try next.run();
}

fn failing_middleware(next: *Next, _: void) !Respond {
    log.info("fail middleware: {s}", .{next.context.request.uri.?});
    return error.FailingMiddleware;
}

pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t: Tardy = try .init(init.gpa, init.io, .{ .threading = .single });
    defer t.deinit();

    const num: i8 = 12;

    var router: Router = try .init(init.gpa, &.{
        Middleware.init({}, passing_middleware).layer(),
        Route.init("/").get(num, root_handler).layer(),
        Middleware.init({}, failing_middleware).layer(),
        Route.init("/").post(num, root_handler).layer(),
        Route.init("/fail").get(num, root_handler).layer(),
    }, .{});
    defer router.deinit(allocator);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    var socket: Socket = try .init(init.io, .{ .tcp = .{ .host = host, .port = port } });
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
