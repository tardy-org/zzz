pub const Middleware = @This();

data: WithData,

pub fn init(args: anytype, func: TypedFn(@TypeOf(args))) Middleware {
    return .{
        .data = .{
            .func = @ptrCast(func),
            .args = .init(args),
        },
    };
}

pub fn layer(middleware: Middleware) Layer {
    return .{ .middleware = middleware.data };
}

pub const Layer = union(enum) {
    /// Route
    route: Route,
    /// Middleware
    middleware: WithData,
};

pub const Next = struct {
    ctx: *const http.Context,
    middlewares: []const WithData,
    handler: Route.Handler.WithData,

    pub fn run(next: *Next) !Respond {
        if (next.middlewares.len > 0) {
            const middleware = next.middlewares[0];
            next.middlewares = next.middlewares[1..];
            return try middleware.func(next, middleware.args);
        } else return try next.handler.handler_fn(next.ctx, next.handler.args);
    }
};

pub const Fn = *const fn (*Next, core.Args) anyerror!Respond;

pub fn TypedFn(comptime T: type) type {
    return *const fn (*Next, T) anyerror!Respond;
}

pub const WithData = struct {
    func: Fn,
    args: core.Args,
};

const log = std.log.scoped(.@"zzz/router/middleware");

const std = @import("std");
const assert = std.debug.assert;

const zzz = @import("../../root.zig");
const core = zzz.core;
const http = zzz.http;
const Respond = http.Respond;
const Route = @import("Route.zig");
