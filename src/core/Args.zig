pub const Args = enum(usize) {
    null = 0,
    true = 1,
    false = 2,
    void = 3,
    _,

    /// Wraps the given value into a specified integer type.
    /// The value must fit within the size of the given I.
    pub fn init(value: anytype) Args {
        const From = @TypeOf(value);
        const To = usize;
        comptime assertValidWrapping(To, From);

        return context: {
            switch (comptime @typeInfo(@TypeOf(value))) {
                .pointer => break :context @fromBackingInt(@intFromPtr(value)),
                .void => break :context .void,
                .int => |info| {
                    const uint = @Int(.unsigned, info.bits);
                    break :context @fromBackingInt(@as(uint, @bitCast(value)));
                },
                .comptime_int => break :context @fromBackingInt(value),
                .float => |info| {
                    const uint = @Int(.unsigned, info.bits);
                    break :context @fromBackingInt(@as(uint, @bitCast(value)));
                },
                .comptime_float => break :context @fromBackingInt(@as(To, @bitCast(
                    value,
                ))),
                .@"struct" => |info| {
                    switch (info.layout) {
                        .@"packed" => {
                            const uint = @Int(.unsigned, @typeInfo(
                                info.backing_integer.?,
                            ).int.bits);
                            break :context @fromBackingInt(@as(uint, @bitCast(value)));
                        },
                        else => {
                            // auto layout struct must have a handle field
                            break :context init(value.handle);
                        },
                    }
                },
                .bool => break :context if (value) .true else .false,
                .optional => break :context if (value) |v| init(v) else .null,
                else => @compileError(
                    "wrapping unsupported type: " ++ @typeName(From),
                ),
            }
        };
    }

    /// Unwraps a specified type from Args.
    pub fn decode_as(encoded: Args, comptime To: type) To {
        const value = @backingInt(encoded);
        const From = @TypeOf(value);
        comptime assertValidWrapping(From, To);

        return context: {
            switch (comptime @typeInfo(To)) {
                .pointer => break :context @ptrFromInt(value),
                .void => break :context {},
                .int => |info| {
                    const uint = @Int(.unsigned, info.bits);
                    break :context @bitCast(@as(uint, @intCast(value)));
                },
                .float => |info| {
                    const uint = @Int(.unsigned, info.bits);
                    const float = std.meta.Float(info.bits);
                    break :context @as(float, @bitCast(@as(uint, @intCast(value))));
                },
                .@"struct" => |info| {
                    switch (info.layout) {
                        .@"packed" => {
                            const uint = @Int(.unsigned, @typeInfo(
                                info.backing_integer.?,
                            ).int.bits);
                            break :context @bitCast(@as(uint, @intCast(value)));
                        },
                        else => {
                            // auto layout struct must have a handle field
                            const handle: To = .{ .handle = encoded.decode_as(
                                @FieldType(To, "handle"),
                            ) };
                            break :context handle;
                        },
                    }
                },
                .bool => {
                    assert(encoded == .true or encoded == .false);
                    break :context if (encoded == .false) false else true;
                },
                .optional => |info| break :context if (encoded == .null)
                    null
                else
                    encoded.decode_as(info.child),
                else => unreachable,
            }
        };
    }

    fn raw(encoded: Args) usize {
        return @backingInt(encoded);
    }

    fn assertValidWrapping(comptime From: type, comptime To: type) void {
        assert(@typeInfo(From) == .int);
        assert(@typeInfo(From).int.signedness == .unsigned);

        switch (comptime @typeInfo(To)) {
            else => {
                @branchHint(.likely);
                assert(@bitSizeOf(To) <= @bitSizeOf(From));
            },
            .optional => |opt| {
                @branchHint(.likely);
                assert(@bitSizeOf(opt.child) <= @bitSizeOf(From));
            },
            .@"struct" => |s| {
                switch (s.layout) {
                    .@"packed" => {
                        @branchHint(.likely);
                        assert(@bitSizeOf(To) <= @bitSizeOf(From));
                    },
                    else => {
                        @branchHint(.unlikely);
                        assert(@hasField(To, "handle"));
                    },
                }
            },
        }
    }
};

test "wrap/unwrap - integers" {
    comptime for ([_]type{ u8, u16, u32, i8, i16, i32 }) |encode_t| {
        const value: encode_t = 42;
        const encoded: Args = .init(value);
        try testing.expectEqual(42, encoded.raw());
    };

    comptime for (&.{ .{ usize, u8 }, .{ usize, i16 } }) |t| {
        const encode_t, const decode_t = t;
        const value: encode_t = 42;
        const encoded: Args = .init(value);
        try testing.expectEqual(42, encoded.decode_as(decode_t));
    };
}

test "wrap/unwrap - floats" {
    comptime for ([_]type{ f32, f64 }) |t| {
        const value: t = 3.14159;
        const encoded: Args = .init(value);
        try testing.expectEqual(value, encoded.decode_as(t));
    };
}

test "wrap/unwrap - booleans" {
    comptime for (.{ true, false }) |boolean| {
        const value: bool = boolean;
        const encoded: Args = .init(value);
        try testing.expectEqual(boolean, encoded.decode_as(bool));
    };
    const true_t: Args, const false_t: Args = .{ .true, .false };
    try testing.expectEqual(true, true_t.decode_as(bool));
    try testing.expectEqual(false, false_t.decode_as(bool));
}

test "wrap/unwrap - optionals" {
    {
        const optional_int: ?i32 = 42;
        const encoded: Args = .init(optional_int);

        try testing.expectEqual(42, encoded.raw());
        try testing.expectEqual(42, encoded.decode_as(?i32));
    }
    {
        const optional_none: ?i32 = null;
        const encoded: Args = .init(optional_none);
        try testing.expectEqual(0, encoded.raw());
        try testing.expectEqual(null, encoded.decode_as(?i32));
    }
}

test "wrap/unwrap - void" {
    const encoded: Args = .init({});
    try testing.expectEqual(.void, encoded);
    try testing.expectEqual({}, encoded.decode_as(void));
}

test "wrap/unwrap - pointers" {
    var value: i32 = 42;
    const ptr = &value;

    const encoded: Args = .init(ptr);
    const decoded = encoded.decode_as(*i32);

    try testing.expectEqual(&value, decoded);
    try testing.expectEqual(42, decoded.*);
}

test "wrap/unwrap - packed/extern/auto struct" {
    {
        const Handle = packed struct {
            handle: i32,
        };
        const handle: Handle = .{ .handle = 42 };
        const encoded: Args = .init(handle);
        const decoded = encoded.decode_as(Handle);

        try testing.expectEqual(handle.handle, decoded.handle);
        try testing.expectEqual(42, encoded.raw());
    }
    {
        const Handle = extern struct {
            handle: i32,
        };
        const handle: Handle = .{ .handle = 42 };
        const encoded: Args = .init(handle);
        const decoded = encoded.decode_as(Handle);

        try testing.expectEqual(handle.handle, decoded.handle);
        try testing.expectEqual(42, encoded.raw());
    }
    {
        const Handle = struct {
            handle: i32,
        };
        const handle: Handle = .{ .handle = 42 };
        const encoded: Args = .init(handle);
        const decoded = encoded.decode_as(Handle);

        try testing.expectEqual(handle.handle, decoded.handle);
        try testing.expectEqual(42, encoded.raw());
    }
}

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
