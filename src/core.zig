pub const string_map = @import("core/string_map.zig");
pub const Storage = @import("core/Storage.zig");
pub const Args = @import("core/Args.zig").Args;
pub const Pseudoslice = @import("core/Pseudoslice.zig");

pub fn Pair(comptime A: type, comptime B: type) type {
    return struct { A, B };
}

pub const Size = enum(u32) {
    @"2KiB" = 2 * kb,
    @"4KiB" = 4 * kb,
    @"8KiB" = 8 * kb,
    @"16KiB" = 16 * kb,
    @"32KiB" = 32 * kb,
    @"64KiB" = 64 * kb,
    @"128KiB" = 128 * kb,
    @"256KiB" = 256 * kb,
    @"512KiB" = 512 * kb,
    @"1MiB" = 1 * kb * kb,
    @"2MiB" = 2 * kb * kb,
    @"4MiB" = 4 * kb * kb,
    @"8MiB" = 8 * kb * kb,
    _,

    const kb = 1024;

    pub fn Usize(size: Size) usize {
        return @backingInt(size);
    }

    pub fn Bytes(size: usize) Size {
        return @fromBackingInt(@intCast(size));
    }

    pub fn KiB(size: usize) Size {
        return @fromBackingInt(@intCast(size * kb));
    }

    pub fn MiB(size: usize) Size {
        return @fromBackingInt(@intCast(size * kb * kb));
    }
};
