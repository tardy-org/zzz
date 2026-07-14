/// HTTP Context. Contains all of the various information
/// that will persist throughout the lifetime of this Request/Response.
pub const Context = @This();

allocator: std.mem.Allocator,
header_writer: *Io.Writer,
runtime: *Runtime,
/// The Request that triggered this handler.
request: *const Request,
response: *Response,
/// Storage
storage: *core.TypedStorage,
/// Socket for this Connection.
socket: SecureSocket,
/// Slice of the URL Slug Captures
captures: []const Capture,
/// Map of the KV Query pairs in the URL
queries: *const string_map.AnyCase,

const std = @import("std");
const Io = std.Io;

const zzz = @import("../root.zig");
const core = zzz.core;
const string_map = core.string_map;
const Runtime = zzz.tardy.Runtime;
const SecureSocket = zzz.secsock.SecureSocket;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Capture = @import("router/routing_trie.zig").Capture;
