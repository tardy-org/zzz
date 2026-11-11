pub const Close = enum(u16) {
    /// Indicates a normal closure, meaning that the purpose for
    /// which the connection was established has been fulfilled
    @"Normal Closure" = 1000,
    /// Indicates that an endpoint is "going away", such as a server
    /// going down or a browser having navigated away from a page.
    @"Going Away" = 1001,
    /// Indicates that an endpoint is terminating the connection due
    /// to a protocol error.
    @"Protocol Error" = 1002,
    /// Indicates that an endpoint is terminating the connection
    /// because it has received a type of data it cannot accept (e.g., an
    /// endpoint that understands only text data MAY send this if it
    /// receives a binary message).
    @"Invalid Frame Data Type" = 1003,
    /// Is a reserved value and MUST NOT be set as a status code in a
    /// Close control frame by an endpoint.  It is designated for use in
    /// applications expecting a status code to indicate that no status
    /// code was actually present
    @"No Status Code Present" = 1005,
    /// Is a reserved value and MUST NOT be set as a status code in a
    /// Close control frame by an endpoint.  It is designated for use in
    /// applications expecting a status code to indicate that the
    /// connection was closed abnormally, e.g., without sending or
    /// receiving a Close control frame
    @"Connection Closed Abnormally" = 1006,
    /// Indicates that an endpoint is terminating the connection
    /// because it has received data within a message that was not
    /// consistent with the type of the message (e.g., non-UTF-8 [RFC3629]
    /// data within a text message)
    @"Invalid UTF8" = 1007,
    /// Indicates that an endpoint is terminating the connection
    /// because it has received a message that violates its policy.  This
    /// is a generic status code that can be returned when there is no
    /// other more suitable status code (e.g., 1003 or 1009) or if there
    /// is a need to hide specific details about the policy
    @"Policy Violated" = 1008,
    /// Indicates that an endpoint is terminating the connection
    /// because it has received a message that is too big for it to
    /// process
    @"Oversized Message" = 1009,
    /// Indicates that an endpoint (client) is terminating the
    /// connection because it has expected the server to negotiate one or
    /// more extension, but the server didn't return them in the response
    /// message of the WebSocket handshake.  The list of extensions that
    /// are needed SHOULD appear in the /reason/ part of the Close frame.
    /// Note that this status code is not used by the server, because it
    /// can fail the WebSocket handshake instead.
    @"Expected Extension" = 1010,
    // Indicates that a server is terminating the connection because
    // it encountered an unexpected condition that prevented it from
    // fulfilling the request
    @"Unexpected Condition" = 1011,
    /// Is a reserved value and MUST NOT be set as a status code in a
    /// Close control frame by an endpoint.  It is designated for use in
    /// applications expecting a status code to indicate that the
    /// connection was closed due to a failure to perform a TLS handshake
    /// (e.g., the server certificate can't be verified)
    @"TLS Handshake Failed" = 1015,

    _,

    comptime {
        std.debug.assert(@sizeOf(Close) == 2);
    }
};

const std = @import("std");
