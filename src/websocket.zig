//! The WebSocket Protocol enables two-way communication between a client
//! running untrusted code in a controlled environment to a remote host
//! that has opted-in to communications from that code.
pub const Frame = @import("websocket/Frame.zig");
pub const handshake = @import("websocket/handshake.zig");
pub const Server = @import("websocket/Server.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
