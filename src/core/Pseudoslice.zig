// The Pseudoslice will basically stitch together two different buffers, using
// a third provided buffer as the output.

pub const Pseudoslice = @This();

first: []const u8,
second: []const u8,
shared: []u8,
len: usize,

pub fn init(first: []const u8, second: []const u8, shared: []u8) Pseudoslice {
    return .{
        .first = first,
        .second = second,
        .shared = shared,
        .len = first.len + second.len,
    };
}

/// Operates like a slice. That means it does not capture the end.
/// Start is an inclusive bound and end is an exclusive bound.
pub fn get(pseudoslice: *const Pseudoslice, start: usize, end: usize) []const u8 {
    debug.assert(end >= start);
    debug.assert(pseudoslice.shared.len >= end - start);
    const clamped_end = @min(end, pseudoslice.len);

    if (start < pseudoslice.first.len) {
        if (clamped_end <= pseudoslice.first.len) {
            // within first slice
            return pseudoslice.first[start..clamped_end];
        } else {
            // across both slices
            const first_len = pseudoslice.first.len - start;
            const second_len = clamped_end - pseudoslice.first.len;
            const total_len = clamped_end - start;

            if (pseudoslice.first.ptr == pseudoslice.shared.ptr) {
                // just copy over the second.
                @memcpy(
                    pseudoslice.shared[pseudoslice.first.len..][0..second_len],
                    pseudoslice.second[0..second_len],
                );
                return pseudoslice.shared[start..clamped_end];
            } else {
                // copy both over.
                @memcpy(
                    pseudoslice.shared[0..first_len],
                    pseudoslice.first[start..],
                );
                @memcpy(
                    pseudoslice.shared[first_len..][0..second_len],
                    pseudoslice.second[0..second_len],
                );
                return pseudoslice.shared[0..total_len];
            }
        }
    } else {
        // within second slice
        const second_start = start - pseudoslice.first.len;
        const second_end = clamped_end - pseudoslice.first.len;
        return pseudoslice.second[second_start..second_end];
    }
}

test "Pseudoslice General" {
    var buffer: [1024]u8 = @splat(0);
    const value = "hello, my name is muki";
    var pseudo: Pseudoslice = .init(
        value[0..6],
        value[6..],
        buffer[0..],
    );

    for (0..pseudo.len) |i| {
        for (0..i) |j| try testing.expectEqualStrings(
            value[j..i],
            pseudo.get(j, i),
        );
    }
}

test "Pseudoslice Empty Second" {
    var buffer: [1024]u8 = @splat(0);
    const value = "hello, my name is muki";
    var pseudo: Pseudoslice = .init(
        value[0..],
        &.{},
        buffer[0..],
    );

    for (0..pseudo.len) |i| try testing.expectEqualStrings(
        value[0..i],
        pseudo.get(0, i),
    );
}

test "Pseudoslice First and Shared Same" {
    const gpa = testing.allocator;
    const buffer = try gpa.alloc(u8, 1024);
    defer gpa.free(buffer);

    const value = "hello, my name is muki";
    @memcpy(buffer[0..6], value[0..6]);

    var pseudo: Pseudoslice = .init(
        buffer[0..6],
        value[6..],
        buffer,
    );

    for (0..pseudo.len) |i| {
        for (0..i) |j| {
            try testing.expectEqualStrings(
                value[j..i],
                pseudo.get(j, i),
            );
        }
    }
}

const std = @import("std");
const debug = std.debug;
const testing = std.testing;
