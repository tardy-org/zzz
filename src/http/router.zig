const std = @import("std");
const assert = std.debug.assert;

const AnyCaseStringMap = @import("../core/any_case_string_map.zig").AnyCaseStringMap;
const Context = @import("context.zig").Context;
const Mime = @import("mime.zig").Mime;
const Request = @import("request.zig").Request;
const Respond = @import("response.zig").Respond;
const Response = @import("response.zig").Response;
const Layer = @import("router/middleware.zig").Layer;
const Route = @import("router/route.zig").Route;
const TypedHandlerFn = @import("router/route.zig").TypedHandlerFn;
const Bundle = @import("router/routing_trie.zig").Bundle;
const Capture = @import("router/routing_trie.zig").Capture;
const RoutingTrie = @import("router/routing_trie.zig").RoutingTrie;

const log = std.log.scoped(.@"zzz/http/router");

/// Default not found handler: send a plain text response.
pub const default_not_found_handler = struct {
    fn not_found_handler(ctx: *const Context, _: void) !Respond {
        const response = ctx.response;
        response.status = .@"Not Found";
        response.mime = Mime.TEXT;
        response.body = "404 | Not Found";

        return .standard;
    }
}.not_found_handler;

/// Initialize a router with the given routes.
pub const Router = struct {
    /// Router configuration structure.
    pub const Configuration = struct {
        not_found: TypedHandlerFn(void) = default_not_found_handler,
    };

    routes: RoutingTrie,
    configuration: Configuration,

    pub fn init(
        allocator: std.mem.Allocator,
        layers: []const Layer,
        configuration: Configuration,
    ) !Router {
        return .{
            .routes = try .init(allocator, layers),
            .configuration = configuration,
        };
    }

    pub fn deinit(self: *Router, allocator: std.mem.Allocator) void {
        self.routes.deinit(allocator);
    }

    pub fn get_bundle_from_host(
        self: *const Router,
        allocator: std.mem.Allocator,
        path: []const u8,
        captures: []Capture,
        queries: *AnyCaseStringMap,
    ) !Bundle {
        queries.clearRetainingCapacity();

        return try self.routes.get_bundle(allocator, path, captures, queries) orelse .{
            .route = Route.init("").all({}, self.configuration.not_found),
            .captures = captures[0..],
            .queries = queries,
            .duped = &.{},
        };
    }
};
