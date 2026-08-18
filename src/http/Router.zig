/// Initialize a router with the given routes.
pub const Router = @This();

routes: Trie,
configuration: Configuration,

pub fn init(
    gpa: mem.Allocator,
    layers: []const Middleware.Layer,
    configuration: Configuration,
) !Router {
    return .{
        .routes = try .init(gpa, layers),
        .configuration = configuration,
    };
}

pub fn deinit(router: *Router, gpa: mem.Allocator) void {
    router.routes.deinit(gpa);
}

pub fn get_bundle_from_host(
    router: *const Router,
    gpa: mem.Allocator,
    path: []const u8,
    captures: []Trie.Capture,
    queries: *string_map.AnyCase,
) !Trie.Bundle {
    queries.clearRetainingCapacity();

    return try router.routes.get_bundle(
        gpa,
        path,
        captures,
        queries,
    ) orelse .{
        .route = Route.init("").all(
            {},
            router.configuration.not_found,
        ),
        .captures = captures[0..],
        .queries = queries,
        .duped = &.{},
    };
}

/// Router configuration structure.
pub const Configuration = struct {
    not_found: Route.Handler.TypedFn(void) = default_not_found_handler,
};

pub const Query = struct {
    key: []const u8,
    value: []const u8,
};

/// Default not found handler: send a plain text response.
pub const default_not_found_handler = struct {
    fn notFound(ctx: *const Context, _: void) !Respond {
        const response = ctx.response;
        response.status = .@"Not Found";
        response.mime = .TEXT;
        response.body = "404 | Not Found";

        return .standard;
    }
}.notFound;

const log = std.log.scoped(.@"zzz/http/router");

const std = @import("std");
const mem = std.mem;

const zzz = @import("../root.zig");
const string_map = zzz.core.string_map;
const http = zzz.http;
const Context = http.Context;
const Mime = http.Mime;
const Request = http.Request;
const Respond = http.Respond;
pub const FsDir = @import("router/FsDir.zig");
pub const Middleware = @import("router/Middleware.zig");
pub const Route = @import("router/Route.zig");
pub const Trie = @import("router/Trie.zig");
