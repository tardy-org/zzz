const Tardy = tardy.Tardy(.auto);

fn hello_world(ctx: *const http.Context, _: void) !http.Respond {
    var iter = ctx.request.cookies.iterator();
    while (iter.next()) |kv|
        log.debug("cookie: k={s} v={s}", .{
            kv.key_ptr.*,
            kv.value_ptr.*,
        });

    const cookie: http.Cookie = .init("example_cookie", "abcdef123");
    return ctx.response.apply(.{
        .status = .OK,
        .mime = .HTML,
        .body = "Hello, world!",
        .headers = &.{
            .{ "Set-Cookie", try cookie.to_string_alloc(ctx.allocator) },
        },
    });
}

pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    const transport: Secsock.Unsecured = .empty;
    const tcp = try transport.tcp(init.gpa, .{
        .host = host,
        .port = port,
    });
    defer tcp.deinit(init.gpa);

    var router: http.Router = try .init(init.gpa, &.{
        Route.init("/").get({}, hello_world).layer(),
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

    var t: Tardy = try .init(init.gpa, init.io, .{
        .threading = .single,
    });
    defer t.deinit();

    try t.entry(
        params,
        struct {
            fn entry(rt: *tardy.Runtime, p: EntryParams) !void {
                const server: http.Server = .init(.{
                    .stack_size = .@"1MiB",
                    .socket_buffer_size = .@"2KiB",
                    .max_keepalive_count = null,
                    .max_connection_count = 10,
                });

                try server.serve(rt, p.router, p.tcp);
                defer server.deinit();
            }
        }.entry,
    );
}

const log = std.log.scoped(.@"examples/cookies");

const std = @import("std");

const zzz = @import("zzz");
const http = zzz.http;
const tardy = zzz.tardy;
const Secsock = zzz.Secsock;
const Route = http.Router.Route;
