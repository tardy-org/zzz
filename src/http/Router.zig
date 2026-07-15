/// Initialize a router with the given routes.
pub const Router = @This();

routes: Trie,
configuration: Configuration,

pub fn init(
    allocator: mem.Allocator,
    layers: []const Middleware.Layer,
    configuration: Configuration,
) !Router {
    return .{
        .routes = try .init(allocator, layers),
        .configuration = configuration,
    };
}

pub fn deinit(self: *Router, allocator: mem.Allocator) void {
    self.routes.deinit(allocator);
}

pub fn get_bundle_from_host(
    self: *const Router,
    allocator: mem.Allocator,
    path: []const u8,
    captures: []Trie.Capture,
    queries: *string_map.AnyCase,
) !Trie.Bundle {
    queries.clearRetainingCapacity();

    return try self.routes.get_bundle(
        allocator,
        path,
        captures,
        queries,
    ) orelse .{
        .route = Route.init("").all(
            {},
            self.configuration.not_found,
        ),
        .captures = captures[0..],
        .queries = queries,
        .duped = &.{},
    };
}

const log = std.log.scoped(.@"zzz/http/router");

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
    fn not_found_handler(ctx: *const Context, _: void) !Respond {
        const response = ctx.response;
        response.status = .@"Not Found";
        response.mime = .TEXT;
        response.body = "404 | Not Found";

        return .standard;
    }
}.not_found_handler;

const std = @import("std");
const mem = std.mem;

const zzz = @import("../root.zig");
const string_map = zzz.core.string_map;
const http = zzz.http;
const Context = http.Context;
const Mime = http.Mime;
const Request = http.Request;
const Respond = http.Respond;
pub const Middleware = @import("router/Middleware.zig");
pub const Route = @import("router/Route.zig");
pub const Trie = @import("router/Trie.zig");
pub const FsDir = @import("router/FsDir.zig");
