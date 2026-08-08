pub const string_map = @import("core/string_map.zig");
pub const Storage = @import("core/Storage.zig");
pub const Args = @import("core/Args.zig").Args;
pub const Pseudoslice = @import("core/Pseudoslice.zig");

pub fn Pair(comptime A: type, comptime B: type) type {
    return struct { A, B };
}
