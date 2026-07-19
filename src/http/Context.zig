/// HTTP Context. Contains all of the various information
/// that will persist throughout the lifetime of this Request/Response.
pub const Context = @This();

allocator: std.mem.Allocator,
header_writer: *Io.Writer,
runtime: *Runtime,
/// The Request that triggered this handler.
request: *const http.Request,
response: *http.Response,
/// Storage
storage: *core.TypedStorage,
/// Socket for this Connection.
socket: secsock.SecureSocket,
/// Slice of the URL Slug Captures
captures: []const Trie.Capture,
/// Map of the KV Query pairs in the URL
queries: *const string_map.AnyCase,

const std = @import("std");
const Io = std.Io;

const zzz = @import("../root.zig");
const core = zzz.core;
const string_map = core.string_map;
const http = zzz.http;
const Runtime = zzz.tardy.Runtime;
const secsock = zzz.secsock;
const Trie = @import("router/Trie.zig");
