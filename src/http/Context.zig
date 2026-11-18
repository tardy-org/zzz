/// HTTP Context. Contains all of the various information
/// that will persist throughout the lifetime of this Request/Response.
pub const Context = @This();

arena: mem.Allocator,
header_writer: *Io.Writer,
runtime: *Runtime,
/// The Request that triggered this handler.
request: *const http.Request,
response: *http.Response,
websocket: ?struct {
    request: *const zzz.websocket.Frame,
    response: *zzz.websocket.Frame,
},
/// Storage
storage: *core.Storage,
/// TCP Socket for this Connection.
tls: *Secsock,
/// Slice of the URL Slug Captures
captures: []const Trie.Capture,
/// Map of the KV Query pairs in the URL
queries: *const http.Queries,

const std = @import("std");
const mem = std.mem;
const Io = std.Io;

const zzz = @import("zzz");
const core = zzz.core;
const http = zzz.http;
const Runtime = zzz.tardy.Runtime;
const Secsock = zzz.Secsock;

const Trie = @import("router/Trie.zig");
