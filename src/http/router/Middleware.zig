pub const Middleware = @This();

inner: WithData,

pub fn init(args: anytype, func: TypedFn(@TypeOf(args))) Middleware {
    return .{
        .inner = .{
            .func = @ptrCast(func),
            .args = .init(args),
        },
    };
}

pub fn layer(self: Middleware) Layer {
    return .{ .middleware = self.inner };
}

pub const Layer = union(enum) {
    /// Route
    route: Route,
    /// Middleware
    middleware: WithData,
};

pub const Next = struct {
    context: *const http.Context,
    middlewares: []const WithData,
    handler: Route.Handler.WithData,

    pub fn run(self: *Next) !Respond {
        if (self.middlewares.len > 0) {
            const middleware = self.middlewares[0];
            self.middlewares = self.middlewares[1..];
            return try middleware.func(self, middleware.args);
        } else return try self.handler.handler_fn(self.context, self.handler.args);
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
