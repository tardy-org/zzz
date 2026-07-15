pub const Context = @import("http/Context.zig");
pub const Cookie = @import("http/Cookie.zig");
pub const Date = @import("http/Date.zig");
pub const form = @import("http/form.zig");
pub const Method = @import("http/method.zig").Method;
pub const middleware = @import("http/middleware.zig");
pub const Mime = @import("http/Mime.zig");
pub const Request = @import("http/Request.zig");
pub const Response = @import("http/Response.zig");
pub const Router = @import("http/Router.zig");
pub const Server = @import("http/Server.zig");
pub const SSE = @import("http/SSE.zig");
pub const Status = @import("http/status.zig").Status;

pub const Respond = enum {
    // When we are returning a real HTTP request, we use this.
    standard,
    // If we responded and we want to give control back to the HTTP engine.
    responded,
    // If we want the connection to close.
    close,
};

pub const Encoding = enum {
    gzip,
    compress,
    deflate,
    br,
    zstd,
};

pub const Error = error{
    TooManyHeaders,
    ContentTooLarge,
    MalformedRequest,
    InvalidMethod,
    URITooLong,
    HTTPVersionNotSupported,
};
