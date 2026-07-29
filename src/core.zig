pub const string_map = @import("core/string_map.zig");
pub const TypedStorage = @import("core/TypedStorage.zig");
pub const Args = @import("core/Args.zig").Args;
pub const Pseudoslice = @import("core/Pseudoslice.zig");

pub fn Pair(comptime A: type, comptime B: type) type {
    return struct { A, B };
}
