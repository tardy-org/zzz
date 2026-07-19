# Getting Started
zzz is a networking framework (HTTP) that allows for modularity and flexibility in design. For most use cases, this flexibility is not a requirement and so various defaults are provided.

For this guide, we will assume that you are running on a supported platform.
This is the current latest release.

`zig fetch --save 'git+https://github.com/tardy-org/zzz#v0.3.2'`

## Hello, World!
We can write a quick example that serves out "Hello, World" responses to any client that connects to the server. This example is derived from the one that is provided within the `examples/basic` directory.

```zig
const std = @import("std");

const zzz = @import("zzz");
const http = zzz.http;
const tardy = zzz.tardy;
const Runtime = tardy.Runtime;
const Socket = tardy.net.Socket;
const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = Router.Route;
const Respond = http.Respond;

const log = std.log.scoped(.@"examples/basic");

const Tardy = tardy.Tardy(.auto);

fn base_handler(ctx: *const Context, _: void) !Respond {
    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = "Hello, world!",
    });
}

pub fn main(init: std.process.Init) !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var t: Tardy = try .init(init.gpa, init.io, .{ .threading = .auto });
    defer t.deinit();

    var router: Router = try .init(init.gpa, &.{
        Route.init("/").get({}, base_handler).layer(),
    }, .{});
    defer router.deinit(init.gpa);

    // create socket for tardy
    var socket: Socket = try .init(init.io, .{
        .tcp = .{ .host = host, .port = port },
    });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(4096);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };
    const params: EntryParams = .{ .router = &router, .socket = socket };

    try t.entry(
        params,
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server: Server = .init(.{
                    .stack_size = .@"4MiB",
                    .socket_buffer_bytes = 1024 * 2,
                    .keepalive_count_max = null,
                    .connection_count_max = 1024,
                });
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
```

The snippet above handles all of the basic tasks involved with serving a plaintext route using zzz's HTTP implementation.
