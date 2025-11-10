const std = @import("std");
const Io = std.Io;

const Runtime = @import("tardy").Runtime;
const secsock = @import("secsock");
const SecureSocket = secsock.SecureSocket;

const AnyCaseStringMap = @import("../core/any_case_string_map.zig").AnyCaseStringMap;
const TypedStorage = @import("../core/typed_storage.zig").TypedStorage;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Capture = @import("router/routing_trie.zig").Capture;

/// HTTP Context. Contains all of the various information
/// that will persist throughout the lifetime of this Request/Response.
pub const Context = struct {
    allocator: std.mem.Allocator,
    header_writer: *Io.Writer,
    runtime: *Runtime,
    /// The Request that triggered this handler.
    request: *const Request,
    response: *Response,
    /// Storage
    storage: *TypedStorage,
    /// Socket for this Connection.
    socket: SecureSocket,
    /// Slice of the URL Slug Captures
    captures: []const Capture,
    /// Map of the KV Query pairs in the URL
    queries: *const AnyCaseStringMap,
};
