const Tardy = tardy.Tardy(.auto);

pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    const transport: Secsock.Unsecured = .empty;
    const tcp = try transport.tcp(init.gpa, .{
        .host = host,
        .port = port,
        .backlog = 256,
    });
    defer tcp.deinit(init.gpa);

    var t: Tardy = try .init(init.gpa, init.io, .{
        .threading = .single,
    });
    defer t.deinit();

    const num: i8 = 12;

    var router: http.Router = try .init(init.gpa, &.{
        Middleware.init({}, passing_middleware).layer(),
        Route.init("/").get(num, root_handler).layer(),
        Middleware.init({}, failing_middleware).layer(),
        Route.init("/").post(num, root_handler).layer(),
        Route.init("/fail").get(num, root_handler).layer(),
    }, .{});
    defer router.deinit(init.gpa);

    const EntryParams = struct {
        router: *const http.Router,
        tcp: *const Secsock,
    };
    const params: EntryParams = .{
        .router = &router,
        .tcp = &tcp,
    };

    try t.entry(
        params,
        struct {
            fn entry(rt: *tardy.Runtime, p: EntryParams) !void {
                const server: http.Server = .init(.{});

                try server.serve(rt, p.router, p.tcp);
                defer server.deinit();
            }
        }.entry,
    );
}

fn root_handler(ctx: *const http.Context, id: i8) !http.Respond {
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
    const body = try ctx.arena.print(
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

fn passing_middleware(next: *Middleware.Next, _: void) !http.Respond {
    log.info("pass middleware: {s}", .{next.ctx.request.uri.?});
    try next.ctx.storage.put(next.ctx.arena, usize, 100);
    return try next.run();
}

fn failing_middleware(next: *Middleware.Next, _: void) !http.Respond {
    log.info("fail middleware: {s}", .{next.ctx.request.uri.?});
    return error.FailingMiddleware;
}

const log = std.log.scoped(.@"examples/middleware");

const std = @import("std");

const zzz = @import("zzz");
const http = zzz.http;
const tardy = zzz.tardy;
const Secsock = zzz.Secsock;
const Route = http.Router.Route;
const Middleware = http.Router.Middleware;
