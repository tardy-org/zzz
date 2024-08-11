const std = @import("std");
const assert = std.debug.assert;
const Route = @import("route.zig").Route;
const Capture = @import("routing_trie.zig").Capture;
const CapturedRoute = @import("routing_trie.zig").CapturedRoute;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Mime = @import("mime.zig").Mime;
const Context = @import("context.zig").Context;
const log = std.log.scoped(.router);

const RoutingTrie = @import("routing_trie.zig").RoutingTrie;

pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: RoutingTrie,
    /// This makes the router immutable, also making it
    /// thread-safe when shared.
    locked: bool = false,

    pub fn init(allocator: std.mem.Allocator) Router {
        const routes = RoutingTrie.init(allocator) catch unreachable;
        return Router{ .allocator = allocator, .routes = routes, .locked = false };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit();
    }

    pub fn serve_fs_dir(self: *Router, dir_path: []const u8) !void {
        _ = self;
        const dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        @panic("TODO");
    }

    pub fn serve_embedded_file(
        self: *Router,
        path: []const u8,
        comptime mime: ?Mime,
        comptime bytes: []const u8,
    ) !void {
        assert(!self.locked);
        const route = Route.init().get(struct {
            pub fn handler_fn(request: Request, _: Context) Response {
                // Currently commented out as it causes a general slowdown.

                _ = request;
                //const etag = comptime std.fmt.comptimePrint("\"{d}\"", .{std.hash.Crc32.hash(bytes)});

                const response = Response.init(.OK, mime, bytes);

                // If our static item is greater than 1KB,
                // it might be more beneficial to using caching.
                //if (bytes.len > 1024) {
                //    // Search for If-None-Match
                //    for (request.headers[0..request.headers_idx]) |header| {
                //        if (std.mem.eql(u8, header.key, "If-None-Match")) {
                //            if (std.mem.eql(u8, etag, header.value)) {
                //                response.status = .@"Not Modified";
                //                response.body = "";
                //            }
                //        }
                //    }

                //    response.add_header(.{
                //        .key = "ETag",
                //        .value = etag[0..],
                //    }) catch {
                //        response.status = .@"Internal Server Error";
                //        response.body = "Failed at serving embedded file";
                //    };
                //}

                return response;
            }
        }.handler_fn);

        try self.serve_route(path, route);
    }

    pub fn serve_route(self: *Router, path: []const u8, route: Route) !void {
        assert(!self.locked);
        try self.routes.add_route(path, route);
    }

    pub fn get_route_from_host(self: Router, host: []const u8, captures: []Capture) ?CapturedRoute {
        return self.routes.get_route(host, captures);
    }
};
