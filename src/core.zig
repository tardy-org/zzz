pub const string_map = @import("core/string_map.zig");
pub const TypeStorage = @import("core/TypedStorage.zig");
pub const wrapping = @import("core/wrapping.zig");
pub const Pseudoslice = @import("pseudoslice.zig");

pub fn Pair(comptime A: type, comptime B: type) type {
    return struct { A, B };
}
