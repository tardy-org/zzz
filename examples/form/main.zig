const Tardy = tardy.Tardy(.auto);

fn home(ctx: *const http.Context, _: void) !http.Respond {
    const body =
        \\<form>
        \\    <label for="fname">First name:</label>
        \\    <input type="text" id="fname" name="fname"><br><br>
        \\    <label for="lname">Last name:</label>
        \\    <input type="text" id="lname" name="lname"><br><br>
        \\    <label for="age">Age:</label>
        \\    <input type="text" id="age" name="age"><br><br>
        \\    <label for="height">Height:</label>
        \\    <input type="text" id="height" name="height"><br><br>
        \\    <button formaction="/generate" formmethod="get">GET Submit</button>
        \\    <button formaction="/generate" formmethod="post">POST Submit</button>
        \\</form>
    ;

    return ctx.response.apply(.{
        .status = .OK,
        .mime = .HTML,
        .body = body,
    });
}

const UserInfo = struct {
    fname: []const u8,
    mname: []const u8 = "Middle",
    lname: []const u8,
    age: u8,
    height: f32,
    weight: ?[]const u8,
};

fn generate(ctx: *const http.Context, _: void) !http.Respond {
    const info = switch (ctx.request.method.?) {
        .GET => try form.Query(UserInfo).parse(ctx.arena, ctx),
        .POST => try form.Form(UserInfo).parse(ctx.arena, ctx),
        else => return error.UnexpectedMethod,
    };

    const body = try ctx.arena.print(
        "First: {s} | Middle: {s} | Last: {s} | Age: {d} | Height: {d} | Weight: {s}",
        .{
            info.fname,
            info.mname,
            info.lname,
            info.age,
            info.height,
            info.weight orelse "none",
        },
    );

    return ctx.response.apply(.{
        .status = .OK,
        .mime = .TEXT,
        .body = body,
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
        Route.init("/").get({}, home).layer(),
        Route.init("/generate").get(
            {},
            generate,
        ).post(
            {},
            generate,
        ).layer(),
    }, .{});
    defer router.deinit(init.gpa);

    var t: Tardy = try .init(init.gpa, init.io, .{
        .threading = .auto,
    });
    defer t.deinit();

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
            fn entry(rt: *tardy.Runtime, p: EntryParams) !void {
                const server: http.Server = .init(.{
                    .stack_size = .@"1MiB",
                    .socket_buffer_size = .@"2KiB",
                });

                try server.serve(rt, p.router, p.tls);
                defer server.deinit();
            }
        }.entry,
    );
}

const log = std.log.scoped(.@"examples/form");

const std = @import("std");

const zzz = @import("zzz");
const http = zzz.http;
const tardy = zzz.tardy;
const form = http.form;
const Secsock = zzz.Secsock;
const Route = http.Router.Route;
