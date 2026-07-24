/// Structure of a server route definition.
pub const Route = @This();

/// Defined route path.
path: []const u8,
/// Route Handlers.
handlers: [9]?Handler.WithData = @splat(null),

/// Initialize a route for the given path.
pub fn init(path: []const u8) Route {
    return .{ .path = path };
}

/// Returns a comma delinated list of allowed Methods for this route. This
/// is meant to be used as the value for the 'Allow' header in the Response.
pub fn get_allowed(route: Route, allocator: mem.Allocator) ![]const u8 {
    // This gets allocated within the context of the connection's arena.
    const allowed_size = comptime blk: {
        var size = 0;
        for (meta.tags(http.Method)) |method| {
            size += @tagName(method).len + 1;
        }
        break :blk size;
    };

    const buffer = try allocator.alloc(u8, allowed_size);

    var current: []u8 = "";
    inline for (meta.tags(http.Method)) |method| {
        if (route.handlers[@backingInt(method)] != null) {
            current = std.fmt.bufPrint(
                buffer,
                "{t},{s}",
                .{ method, current },
            ) catch unreachable;
        }
    }

    if (current.len == 0) {
        return current;
    } else {
        return current[0 .. current.len - 1];
    }
}

/// Get a defined request handler for the provided method.
/// Return NULL if no handler is defined for this method.
pub fn get_handler(route: Route, method: http.Method) ?Handler.WithData {
    return route.handlers[@backingInt(method)];
}

pub fn layer(route: Route) Middleware.Layer {
    return .{ .route = route };
}

/// Set a handler function for the provided method.
inline fn inner_route(
    route: Route,
    comptime method: http.Method,
    data: anytype,
    handler_fn: Handler.TypedFn(@TypeOf(data)),
) Route {
    const wrapped = wrapping.wrap(usize, data);
    var new_handlers = route.handlers;
    new_handlers[comptime @backingInt(method)] = .{
        .handler = @ptrCast(
            handler_fn,
        ),
        .middlewares = &.{},
        .data = wrapped,
    };

    return .{
        .path = route.path,
        .handlers = new_handlers,
    };
}

/// Set a handler function for all methods.
pub fn all(
    route: Route,
    data: anytype,
    handler_fn: Handler.TypedFn(@TypeOf(data)),
) Route {
    const wrapped = wrapping.wrap(usize, data);
    var new_handlers = route.handlers;

    for (&new_handlers) |*new_handler| {
        new_handler.* = .{
            .handler = @ptrCast(
                handler_fn,
            ),
            .middlewares = &.{},
            .data = wrapped,
        };
    }

    return .{
        .path = route.path,
        .handlers = new_handlers,
    };
}

pub fn get(
    route: Route,
    data: anytype,
    handler_fn: Handler.TypedFn(@TypeOf(data)),
) Route {
    return route.inner_route(.GET, data, handler_fn);
}

pub fn head(
    route: Route,
    data: anytype,
    handler_fn: Handler.TypedFn(@TypeOf(data)),
) Route {
    return route.inner_route(.HEAD, data, handler_fn);
}

pub fn post(
    route: Route,
    data: anytype,
    handler_fn: Handler.TypedFn(@TypeOf(data)),
) Route {
    return route.inner_route(.POST, data, handler_fn);
}

pub fn put(
    route: Route,
    data: anytype,
    handler_fn: Handler.TypedFn(@TypeOf(data)),
) Route {
    return route.inner_route(.PUT, data, handler_fn);
}

pub fn delete(
    route: Route,
    data: anytype,
    handler_fn: Handler.TypedFn(@TypeOf(data)),
) Route {
    return route.inner_route(.DELETE, data, handler_fn);
}

pub fn connect(
    route: Route,
    data: anytype,
    handler_fn: Handler.TypedFn(@TypeOf(data)),
) Route {
    return route.inner_route(.CONNECT, data, handler_fn);
}

pub fn options(
    route: Route,
    data: anytype,
    handler_fn: Handler.TypedFn(@TypeOf(data)),
) Route {
    return route.inner_route(.OPTIONS, data, handler_fn);
}

pub fn trace(
    route: Route,
    data: anytype,
    handler_fn: Handler.TypedFn(@TypeOf(data)),
) Route {
    return route.inner_route(.TRACE, data, handler_fn);
}

pub fn patch(
    route: Route,
    data: anytype,
    handler_fn: Handler.TypedFn(@TypeOf(data)),
) Route {
    return route.inner_route(.PATCH, data, handler_fn);
}

/// Define a GET handler to serve an embedded file.
pub fn embed_file(
    route: *const Route,
    comptime opts: EmbeddedOptions,
    comptime bytes: []const u8,
) Route {
    return route.get({}, struct {
        fn handler_fn(ctx: *const http.Context, _: void) !http.Respond {
            const response = ctx.response;

            const cache_control: []const u8 = if (comptime builtin.mode == .debug)
                "no-cache"
            else
                comptime std.fmt.comptimePrint(
                    "max-age={d}",
                    .{std.time.s_per_day * 30},
                );

            try response.headers.put("Cache-Control", cache_control);

            // If our static item is greater than 1KB,
            // it might be more beneficial to using caching.
            if (comptime bytes.len > 1024) {
                @setEvalBranchQuota(1_000_000);
                const etag = comptime std.fmt.comptimePrint(
                    "\"{d}\"",
                    .{std.hash.Wyhash.hash(0, bytes)},
                );
                try response.headers.put("ETag", etag[0..]);

                if (ctx.request.headers.get("If-None-Match")) |match| {
                    if (mem.eql(u8, etag, match)) {
                        return response.apply(.{
                            .status = .@"Not Modified",
                            .mime = .HTML,
                        });
                    }
                }
            }

            if (opts.encoding) |encoding|
                try response.headers.put("Content-Encoding", @tagName(
                    encoding,
                ));

            return response.apply(.{
                .status = .OK,
                .mime = opts.mime orelse .BIN,
                .body = bytes,
            });
        }
    }.handler_fn);
}

pub const Handler = struct {
    pub const Fn = *const fn (*const http.Context, usize) anyerror!http.Respond;
    pub const WithData = struct {
        handler: Handler.Fn,
        middlewares: []const Middleware.WithData,
        data: usize,
    };
    pub fn TypedFn(comptime T: type) type {
        return *const fn (*const http.Context, T) anyerror!http.Respond;
    }
};

const EmbeddedOptions = struct {
    /// If you are serving a compressed file, please
    /// set the correct encoding type.
    encoding: ?http.Encoding = null,
    mime: ?http.Mime = null,
};

const log = std.log.scoped(.@"zzz/http/route");

const std = @import("std");
const mem = std.mem;
const meta = std.meta;
const assert = std.debug.assert;
const builtin = @import("builtin");

const zzz = @import("../../root.zig");
const http = zzz.http;
const wrapping = zzz.core.wrapping;
const Middleware = @import("Middleware.zig");
