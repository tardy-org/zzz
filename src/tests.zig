test "zzz unit tests" {
    // Core
    _ = core.string_map.AnyCase;
    _ = core.Pseudoslice;
    _ = core.TypedStorage;

    // HTTP
    _ = http.Context;
    _ = http.Date;
    _ = http.Method;
    _ = http.Mime;
    _ = http.Request;
    _ = http.Response;
    _ = http.Server;
    _ = http.SSE;
    _ = http.Status;
    _ = http.form;

    // Router
    _ = http.Router;
    _ = http.Router.Route;
    _ = http.Router.Trie;
}

const zzz = @import("root.zig");
const core = zzz.core;
const http = zzz.http;
