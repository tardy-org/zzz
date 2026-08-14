const std = @import("std");
const flate = std.compress.flate;

const zzz = @import("../../root.zig");
const http = zzz.http;
const Router = http.Router;
const Middleware = Router.Middleware;

const Kind = union(enum) {
    gzip: struct {
        container: flate.Container = .gzip,
        level: flate.Compress.Options = .default,
    },
};

// TODO: add examples to excercis these
/// Compression Middleware.
///
/// Provides a Compression Layer for all routes under this that
/// will properly compress the body and add the proper `Content-Encoding` header.
pub fn Compression(comptime compression: Kind) Middleware.Layer {
    const func: Middleware.TypedFn(void) = switch (compression) {
        .gzip => |gzip| struct {
            fn gzip_mw(next: *Middleware.Next, _: void) !http.Respond {
                const respond = try next.run();
                const response = next.context.response;
                if (response.body) |body| if (body.len != 0 and
                    respond == .standard)
                {
                    var compressed: std.Io.Writer.Allocating = try .initCapacity(
                        next.context.arena,
                        // flate compress requires a buffer > 8
                        if (body.len < 9) body.len + 8 else body.len,
                    );
                    errdefer compressed.deinit();

                    var history_window: [flate.max_window_len]u8 = undefined;
                    var body_stream: flate.Compress = try .init(
                        &compressed.writer,
                        &history_window,
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
