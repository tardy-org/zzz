const std = @import("std");
const log = std.log.scoped(.@"examples/form");

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
const Form = http.Form;
const Query = http.Query;
const Respond = http.Respond;

fn base_handler(ctx: *const Context, _: void) !Respond {
    const body =
        \\<!DOCTYPE html>
        \\<html>
        \\<head><meta charset="UTF-8"></head>
        \\<body>
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
        \\</body>
        \\</html>
    ;

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body,
    });
}

const UserInfo = struct {
    fname: ?[]const u8 = null,
    mname: ?[]const u8 = "Middle",
    lname: ?[]const u8 = null,
    age: ?[]const u8 = null,
    height: ?[]const u8 = null,
    weight: ?[]const u8 = null,
};

fn generate_handler(ctx: *const Context, _: void) !Respond {
    //std.debug.print("Handler entered, method: {any}\n", .{ctx.request.method});
    const info = switch (ctx.request.method.?) {
        .GET => Query(UserInfo).parse(ctx.allocator, ctx) catch |err| {
            std.debug.print("Query parse failed: {}\n", .{err});
            return ctx.response.apply(.{
                .status = .@"Bad Request",
                .mime = http.Mime.TEXT,
                .headers = &.{ .{ "Content-Type", "text/plain; charset=utf-8" } },
                .body = "Invalid or empty query parameters",
            });
        },
        .POST => Form(UserInfo).parse(ctx.allocator, ctx) catch |err| {
            std.debug.print("Form parse failed: {}\n", .{err});
            return ctx.response.apply(.{
                .status = .@"Bad Request",
                .mime = http.Mime.TEXT,
                .headers = &.{ .{ "Content-Type", "text/plain; charset=utf-8" } },
                .body = "Invalid or empty form data",
            });
        },
        else => return error.UnexpectedMethod,
    };

    const fname = info.fname orelse "";
    const mname = info.mname orelse "Middle";
    const lname = info.lname orelse "";
    const age = if (info.age) |v| std.fmt.parseInt(u8, v, 10) catch 0 else 0;
    const height = if (info.height) |v| std.fmt.parseFloat(f32, v) catch 0.0 else 0.0;
    const weight = if (info.weight) |w| if (w.len == 0) "none" else w else "none";

    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "First: {s} | Middle: {s} | Last: {s} | Age: {d} | Height: {d} | Weight: {s}",
        .{
          if (fname.len == 0) "(empty)" else fname,
          if (mname.len == 0) "Middle" else mname,
          if (lname.len == 0) "(empty)" else lname,
          age,
          height,
          weight,
        },
    );

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.TEXT,
        .headers = &.{
            .{ "Content-Type", "text/plain; charset=utf-8" },
        },
        .body = body,
    });
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(allocator, .{ .threading = .auto });
    defer t.deinit();

    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, base_handler).layer(),
        Route.init("/generate").get({}, generate_handler).post({}, generate_handler).layer(),
    }, .{});
    defer router.deinit(allocator);

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
                });
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
