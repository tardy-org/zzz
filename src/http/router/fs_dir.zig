const std = @import("std");
const assert = std.debug.assert;

const Dir = @import("tardy").Dir;
const Runtime = @import("tardy").Runtime;
const Stat = @import("tardy").Stat;
const Stream = @import("tardy").Stream;
const ZeroCopy = @import("tardy").ZeroCopy;

const Context = @import("../context.zig").Context;
const Mime = @import("../mime.zig").Mime;
const Request = @import("../request.zig").Request;
const Respond = @import("../response.zig").Respond;
const Layer = @import("middleware.zig").Layer;
const Route = @import("route.zig").Route;

const log = std.log.scoped(.@"zzz/http/router");

pub const FsDir = struct {
    fn fs_dir_handler(ctx: *const Context, dir: Dir) !Respond {
        if (ctx.captures.len == 0) return ctx.response.apply(.{
            .status = .@"Not Found",
            .mime = Mime.HTML,
        });

        const response = ctx.response;

        // Resolving the requested file.
        const search_path = ctx.captures[0].remaining;
        const file_path_z = try ctx.allocator.dupeSentinel(u8, search_path, 0x0);

        // TODO: check that the path is valid.

        const extension_start = std.mem.lastIndexOfScalar(u8, search_path, '.');
        const mime: Mime = blk: {
            if (extension_start) |start| {
                if (search_path.len - start == 0) break :blk Mime.BIN;
                break :blk Mime.from_extension(search_path[start + 1 ..]);
            } else {
                break :blk Mime.BIN;
            }
        };

        const file = dir.open_file(ctx.runtime, file_path_z, .{ .mode = .read }) catch |e| switch (e) {
            error.NotFound => {
                return ctx.response.apply(.{
                    .status = .@"Not Found",
                    .mime = .HTML,
                });
            },
            else => return e,
        };
        const stat = try file.stat(ctx.runtime);

        var hash: std.hash.Wyhash = .init(0);
        hash.update(std.mem.asBytes(&stat.size));
        if (stat.modified) |modified| {
            hash.update(std.mem.asBytes(&modified.nanoseconds));
        }
        const etag_hash = hash.final();

        const calc_etag = try std.fmt.allocPrint(ctx.allocator, "\"{d}\"", .{etag_hash});
        try response.headers.put("ETag", calc_etag);

        // If we have an ETag on the request...
        if (ctx.request.headers.get("If-None-Match")) |etag| {
            if (std.mem.eql(u8, etag, calc_etag)) {
                // If the ETag matches.
                return ctx.response.apply(.{
                    .status = .@"Not Modified",
                    .mime = .HTML,
                });
            }
        }

        // apply the fields.
        response.status = .OK;
        response.mime = mime;

        response.headers_into_writer(ctx.header_writer, stat.size) catch |err| switch (err) {
            error.WriteFailed => return error.ExceededMaxHttpHeaderSize,
            else => unreachable,
        };
        const headers = ctx.header_writer.buffered();
        const length = try ctx.socket.send_all(ctx.runtime, headers);
        if (headers.len != length) return error.SendingHeadersFailed;

        // Reuse the header_buffer for file read/send
        var buffer = ctx.header_writer.buffer[0..];
        while (true) {
            const read_count = file.read(ctx.runtime, buffer, null) catch |e| switch (e) {
                error.EndOfFile => break,
                else => return e,
            };

            _ = ctx.socket.send(ctx.runtime, buffer[0..read_count]) catch |e| switch (e) {
                error.Closed => break,
                else => return e,
            };
        }

        return .responded;
    }

    /// Serve a Filesystem Directory as a Layer.
    pub fn serve(comptime url_path: []const u8, dir: Dir) Layer {
        const url_with_match_all = comptime std.fmt.comptimePrint(
            "{s}/%r",
            .{std.mem.trimEnd(u8, url_path, "/")},
        );
        log.debug("url with match {s}", .{url_with_match_all});

        return Route.init(url_with_match_all).get(dir, fs_dir_handler).layer();
    }
};
