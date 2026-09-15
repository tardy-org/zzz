/// Internally exposed secsock.
pub const Secsock = @import("secsock");

/// Internally exposed Tardy.
pub const tardy = @import("tardy");

pub const core = @import("core.zig");

/// HyperText Transfer Protocol.
/// Supports: HTTP/1.1
pub const http = @import("http.zig");

/// WebSocket Protocal
pub const websocket = @import("websocket.zig");

/// These are various general configuration
/// options that are important for the actual framework.
///
/// This includes various different options and limits
/// for interacting with the underlying network.
pub const Config = struct {
    /// Stack Size
    ///
    /// If you have a large number of middlewares or
    /// create a LOT of stack memory, you may want to increase this.
    ///
    /// P.S: A lot of functions in the standard library do end up allocating
    /// a lot on the stack (such as std.log).
    ///
    /// Default: 1MB
    stack_size: tardy.Coroutine.Stack = .@"1MiB",
    /// Use a Max Header Size of 8KiB same as Nginx, Tomcat and Httpd but
    /// consider making this configurable
    /// https://stackoverflow.com/questions/686217/maximum-on-http-header-values
    /// Default: 8KiB
    header_size_max: core.Size = .@"8KiB",
    /// Maximum number of header fields in a Request/Response
    /// https://datatracker.ietf.org/doc/html/rfc9110#name-field-limits
    ///
    /// Default: 32
    header_fields_count_max: u32 = 32,
    /// Maximum size (in bytes) of the Request.
    /// https://stackoverflow.com/questions/2880722/can-http-post-be-limitless
    ///
    /// Default: 1MiB
    request_size_max: core.Size = .@"1MiB",
    /// Maximum size (in bytes) of the Request URI.
    /// https://stackoverflow.com/questions/417142/what-is-the-maximum-length-of-a-url-in-different-browsers
    ///
    /// Default: 2KiB
    request_uri_size_max: core.Size = .@"2KiB",
    /// Number of Maximum Concurrent Connections.
    ///
    /// This is applied PER runtime.
    /// zzz will drop/close any connections greater
    /// than this.
    ///
    /// You can set this to `null` to have no maximum.
    ///
    /// Default: `null`
    connection_count_max: ?u32 = null,
    /// Maximum number of Captures in a Route
    ///
    /// Default: 8
    capture_count_max: u16 = 8,
    /// Number of times a Request-Response can happen with keep-alive.
    ///
    /// Setting this to `null` will set no limit.
    ///
    /// Default: `null`
    keepalive_count_max: ?u16 = null,
    /// Amount of `ctx.arena` memory retained after a
    /// Request/Response cycle ends.
    ///
    /// A higher value will increase memory usage but
    /// make allocators faster.
    ///
    /// A lower value will reduce memory usage but
    /// will make allocators slower.
    ///
    /// `null` retain all memory reducing the posibility of
    /// allocating additional memory
    ///
    /// Default: null
    arena_bytes_retained: ?core.Size = null,
    /// Total size of the `zc_recv_buffer` used for handling
    /// a complete Request and Responds cycle.
    ///
    /// This should be multiples of `recv_buffer_size` idealy >= 3
    ///
    /// Default: 1MiB
    recv_zerocopy_size: core.Size = .@"1MiB",
    /// Size (in bytes) of the Recv buffer used per Send/Receive
    /// This is mainly a concern when you are reading in large
    /// requests before responding.
    ///
    /// Default: 256KiB
    recv_buffer_size: core.Size = .@"256KiB",
};

test {
    @import("std").testing.refAllDecls(@This());
}
