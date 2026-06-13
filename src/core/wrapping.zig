const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

/// Special values for Wrapped types.
const Wrapped = enum(usize) {
    null = 0,
    true = 1,
    false = 2,
    void = 3,
};

fn assertValidWrapping(comptime I: type, comptime T: type) void {
    assert(@typeInfo(I) == .int);
    assert(@typeInfo(I).int.signedness == .unsigned);

    switch (comptime @typeInfo(T)) {
        else => {
            @branchHint(.likely);
            assert(@bitSizeOf(T) <= @bitSizeOf(I));
        },
        .@"struct" => |s| {
            switch (s.layout) {
                .@"packed" => {
                    @branchHint(.likely);
                    assert(@bitSizeOf(T) <= @bitSizeOf(I));
                },
                else => {
                    @branchHint(.unlikely);
                    assert(@hasField(T, "handle"));
                },
            }
        },
    }
}

/// Wraps the given value into a specified integer type.
/// The value must fit within the size of the given I.
pub fn wrap(comptime I: type, value: anytype) I {
    const T = @TypeOf(value);
    comptime assertValidWrapping(I, T);

    return context: {
        switch (comptime @typeInfo(@TypeOf(value))) {
            .pointer => break :context @intFromPtr(value),
            .void => break :context @intFromEnum(Wrapped.void),
            .int => |info| {
                const uint = @Int(.unsigned, info.bits);
                break :context @intCast(@as(uint, @bitCast(value)));
            },
            .comptime_int => break :context @intCast(value),
            .float => |info| {
                const uint = @Int(.unsigned, info.bits);
                break :context @intCast(@as(uint, @bitCast(value)));
            },
            .comptime_float => break :context @intCast(@as(I, @bitCast(value))),
            .@"struct" => |info| {
                switch (info.layout) {
                    .@"packed" => {
                        const uint = @Int(.unsigned, @typeInfo(info.backing_integer.?).int.bits);
                        break :context @intCast(@as(uint, @bitCast(value)));
                    },
                    else => {
                        // auto layout struct must have a handle field
                        break :context wrap(I, value.handle);
                    },
                }
            },
            .bool => break :context if (value)
                @intFromEnum(Wrapped.true)
            else
                @intFromEnum(Wrapped.false),
            .optional => break :context if (value) |v|
                wrap(I, v)
            else
                @intFromEnum(Wrapped.null),
            else => @compileError("wrapping unsupported type: " ++ @typeName(@TypeOf(value))),
        }
    };
}

/// Unwraps a specified type from an underlying value.
/// The value must be an unsigned integer type, typically a usize.
pub fn unwrap(comptime T: type, value: anytype) T {
    const I = @TypeOf(value);
    comptime assertValidWrapping(I, T);

    return context: {
        switch (comptime @typeInfo(T)) {
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
                        const uint = @Int(.unsigned, @typeInfo(info.backing_integer.?).int.bits);
                        break :context @bitCast(@as(uint, @intCast(value)));
                    },
                    else => {
                        // auto layout struct must have a handle field
                        const handle: T = .{ .handle = unwrap(@FieldType(T, "handle"), value) };
                        break :context handle;
                    },
                }
            },
            .bool => {
                assert(value == @intFromEnum(Wrapped.true) or value == @intFromEnum(Wrapped.false));
                break :context if (value == @intFromEnum(Wrapped.false)) false else true;
            },
            .optional => |info| break :context if (value == @intFromEnum(Wrapped.null))
                null
            else
                unwrap(info.child, value),
            else => unreachable,
        }
    };
}

test "wrap/unwrap - integers" {
    try testing.expectEqual(42, wrap(usize, @as(u8, 42)));
    try testing.expectEqual(42, wrap(usize, @as(u16, 42)));
    try testing.expectEqual(42, wrap(usize, @as(u32, 42)));

    try testing.expectEqual(42, wrap(usize, @as(i8, 42)));
    try testing.expectEqual(42, wrap(usize, @as(i16, 42)));
    try testing.expectEqual(42, wrap(usize, @as(i32, 42)));

    try testing.expectEqual(42, unwrap(u8, @as(usize, 42)));
    try testing.expectEqual(42, unwrap(i16, @as(usize, 42)));
}

test "wrap/unwrap - floats" {
    const pi_32: f32 = 3.14159;
    const pi_64: f64 = 3.14159;

    const wrapped_f32 = wrap(usize, pi_32);
    const wrapped_f64 = wrap(usize, pi_64);

    try testing.expectEqual(pi_32, unwrap(f32, wrapped_f32));
    try testing.expectEqual(pi_64, unwrap(f64, wrapped_f64));
}

test "wrap/unwrap - booleans" {
    try testing.expectEqual(@intFromEnum(Wrapped.true), wrap(usize, true));
    try testing.expectEqual(@intFromEnum(Wrapped.false), wrap(usize, false));

    try testing.expectEqual(true, unwrap(bool, @as(usize, @intFromEnum(Wrapped.true))));
    try testing.expectEqual(false, unwrap(bool, @as(usize, @intFromEnum(Wrapped.false))));
}

test "wrap/unwrap - optionals" {
    const optional_int: ?i32 = 42;
    const optional_none: ?i32 = null;

    try testing.expectEqual(42, wrap(usize, optional_int));
    try testing.expectEqual(0, wrap(usize, optional_none));

    try testing.expectEqual(42, unwrap(?i32, @as(usize, 42)));
    try testing.expectEqual(null, unwrap(?i32, @as(usize, 0)));
}

test "wrap/unwrap - void" {
    try testing.expectEqual(@intFromEnum(Wrapped.void), wrap(usize, {}));
    try testing.expectEqual({}, unwrap(void, @as(usize, @intFromEnum(Wrapped.void))));
}

test "wrap/unwrap - pointers" {
    var value: i32 = 42;
    const ptr = &value;

    const wrapped = wrap(usize, ptr);
    const unwrapped = unwrap(*i32, wrapped);

    try testing.expectEqual(&value, unwrapped);
    try testing.expectEqual(42, unwrapped.*);
}

test "wrap/unwrap - packed/extern/auto struct" {
    {
        const Handle = packed struct {
            handle: i32,
        };
        const handle: Handle = .{ .handle = 42 };
        const wrapped = wrap(usize, handle);
        const unwrapped = unwrap(Handle, wrapped);

        try testing.expectEqual(handle.handle, unwrapped.handle);
        try testing.expectEqual(42, wrapped);
    }
    {
        const Handle = extern struct {
            handle: i32,
        };
        const handle: Handle = .{ .handle = 42 };
        const wrapped = wrap(usize, handle);
        const unwrapped = unwrap(Handle, wrapped);

        try testing.expectEqual(handle.handle, unwrapped.handle);
        try testing.expectEqual(42, wrapped);
    }
    {
        const Handle = struct {
            handle: i32,
        };
        const handle: Handle = .{ .handle = 42 };
        const wrapped = wrap(usize, handle);
        const unwrapped = unwrap(Handle, wrapped);

        try testing.expectEqual(handle.handle, unwrapped.handle);
        try testing.expectEqual(42, wrapped);
    }
}
