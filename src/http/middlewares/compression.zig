const std = @import("std");

const Respond = @import("../response.zig").Respond;
const Middleware = @import("../router/middleware.zig").Middleware;
const Next = @import("../router/middleware.zig").Next;
const Layer = @import("../router/middleware.zig").Layer;
const TypedMiddlewareFn = @import("../router/middleware.zig").TypedMiddlewareFn;

const Kind = union(enum) { gzip: struct {
    level: std.compress.flate.Compress.Level = .default,
} };

/// Compression Middleware.
///
/// Provides a Compression Layer for all routes under this that
/// will properly compress the body and add the proper `Content-Encoding` header.
pub fn Compression(comptime compression: Kind) Layer {
    const func: TypedMiddlewareFn(void) = switch (compression) {
        .gzip => |_| struct {
            fn gzip_mw(next: *Next, _: void) !Respond {
                const respond = try next.run();
                const response = next.context.response;
                if (response.body) |body| if (respond == .standard) {
                    var compressed = try std.Io.Writer.Allocating.initCapacity(next.context.allocator, body.len);
                    errdefer compressed.deinit();

                    var compress = std.compress.flate.Compress.init(
                        &compressed.writer,
                        &.{},
                        .{ .level = compression.gzip.level, .container = .gzip },
                    );
                    try compress.writer.writeAll(body);
                    try compress.writer.flush();

                    try response.headers.put("Content-Encoding", "gzip");
                    var compressed_list = compressed.toArrayList();
                    response.body = try compressed_list.toOwnedSlice(next.context.allocator);
                    return .standard;
                };

                return respond;
            }
        }.gzip_mw,
    };

    return Middleware.init({}, func).layer();
}
