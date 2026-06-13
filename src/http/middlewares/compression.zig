const std = @import("std");
const flate = std.compress.flate;

const Respond = @import("../response.zig").Respond;
const Middleware = @import("../router/middleware.zig").Middleware;
const Next = @import("../router/middleware.zig").Next;
const Layer = @import("../router/middleware.zig").Layer;
const TypedMiddlewareFn = @import("../router/middleware.zig").TypedMiddlewareFn;

const Kind = union(enum) {
    gzip: struct {
        container: flate.Container = .gzip,
        level: flate.Compress.Options = .default,
    },
};

/// Compression Middleware.
///
/// Provides a Compression Layer for all routes under this that
/// will properly compress the body and add the proper `Content-Encoding` header.
pub fn Compression(comptime compression: Kind) Layer {
    const func: TypedMiddlewareFn(void) = switch (compression) {
        .gzip => |gzip| struct {
            fn gzip_mw(next: *Next, _: void) !Respond {
                const respond = try next.run();
                const response = next.context.response;
                if (response.body) |body| if (respond == .standard) {
                    var compressed: std.Io.Writer.Allocating = try .initCapacity(
                        next.context.allocator,
                        body.len,
                    );
                    errdefer compressed.deinit();

                    var body_stream: flate.Compress = try .init(
                        &compressed.writer,
                        &.{},
                        gzip.container,
                        gzip.level,
                    );
                    try body_stream.writer.writeAll(body);
                    try body_stream.writer.flush();

                    try response.headers.put("Content-Encoding", "gzip");
                    response.body = try compressed.toOwnedSlice();
                    return .standard;
                };

                return respond;
            }
        }.gzip_mw,
    };

    return Middleware.init({}, func).layer();
}
