const Tardy = tardy.Tardy(.auto);

fn sse_handler(ctx: *const http.Context, _: void) !http.Respond {
    var sse: http.SSE = try .init(ctx);

    while (true) {
        sse.send(.{ .data = "hello from handler!" }) catch break;
        try Runtime.Timer.delay(ctx.runtime, .{
            .nanoseconds = 3 * std.time.ns_per_s,
        });
    }

    return .responded;
}

// Test with: browser tab with http://localhost:9862/
// And another with http://localhost:9862/stream
// Then click `Start SSE Connection` and `Send Message` in the first tab
pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var t: Tardy = try .init(init.gpa, init.io, .{
        .threading = .single,
    });
    defer t.deinit();

    const router: http.Router = try .init(init.gpa, &.{
        Route.init("/").embed_file(
            .{ .mime = .HTML },
            @embedFile("./index.html"),
        ).layer(),
        Route.init("/stream").get(
            {},
            sse_handler,
        ).layer(),
    }, .{});

    const transport: Secsock.Unsecured = .empty;
    const tcp = try transport.tcp(init.gpa, .{
        .host = host,
        .port = port,
    });
    defer tcp.deinit(init.gpa);

    const EntryParams = struct {
        router: *const http.Router,
        tls: *const Secsock,
    };
    const params: EntryParams = .{
        .router = &router,
        .tls = &tcp,
    };

    try t.entry(
        params,
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                const server: http.Server = .init(.{
                    .stack_size = .@"2MiB",
                    .socket_buffer_bytes = 1024 * 2,
                });

                try server.serve(rt, p.router, p.tls);
                defer server.deinit();
            }
        }.entry,
    );
}

const log = std.log.scoped(.@"examples/sse");

const std = @import("std");

const zzz = @import("zzz");
const http = zzz.http;
const tardy = zzz.tardy;
const Secsock = zzz.Secsock;
const Runtime = tardy.Runtime;
const Route = http.Router.Route;
