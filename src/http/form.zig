/// Parses Form data from a request body in `x-www-form-urlencoded` format.
pub fn Form(comptime T: type) type {
    return struct {
        pub fn parse(ctx: *const Context) !T {
            var form: Value = .empty;
            defer {
                var it = form.iterator();
                while (it.next()) |entry| {
                    ctx.arena.free(entry.key_ptr.*);
                    ctx.arena.free(entry.value_ptr.*);
                }
                form.deinit(ctx.arena);
            }

            if (ctx.request.body) |body|
                try construct_map_from_body(ctx.arena, &form, body)
            else
                return error.BodyEmpty;

            return parse_struct(ctx.arena, T, &form);
        }
    };
}

/// Parses Form data from request URL query parameters.
pub fn Query(comptime T: type) type {
    return struct {
        pub fn parse(ctx: *const Context) !T {
            return parse_struct(ctx.arena, T, ctx.queries);
        }
    };
}

fn parse_struct(
    gpa: mem.Allocator,
    comptime T: type,
    form: *const Value,
) !T {
    var ret: T = undefined;
    debug.assert(@typeInfo(T) == .@"struct");
    const struct_info = @typeInfo(T).@"struct";
    inline for (
        struct_info.field_types,
        struct_info.field_names,
        struct_info.field_attrs,
    ) |field_type, field_name, field_attrs| {
        const entry = form.getEntry(field_name);

        if (entry) |e| {
            @field(ret, field_name) = try parse_from(
                gpa,
                field_type,
                field_name,
                e.value_ptr.*,
            );
        } else if (field_attrs.defaultValue(field_type)) |default| {
            @field(ret, field_name) = default;
        } else if (@typeInfo(field_type) == .optional) {
            @field(ret, field_name) = null;
        } else return error.FieldEmpty;
    }

    return ret;
}

fn parse_from(
    gpa: mem.Allocator,
    comptime T: type,
    comptime name: []const u8,
    value: []const u8,
) !T {
    return switch (@typeInfo(T)) {
        .int => |info| switch (info.signedness) {
            .unsigned => try fmt.parseUnsigned(T, value, 10),
            .signed => try fmt.parseInt(T, value, 10),
        },
        .float => try fmt.parseFloat(T, value),
        .optional => |info| try parse_from(
            gpa,
            info.child,
            name,
            value,
        ),
        .@"enum" => std.meta.stringToEnum(T, value) orelse
            return error.InvalidEnumValue,
        .bool => mem.eql(u8, value, "true"),
        else => switch (T) {
            []const u8 => try gpa.dupe(u8, value),
            [:0]const u8 => try gpa.dupeSentinel(u8, value),
            else => debug.panic("Unsupported field type \"{t}\"", .{T}),
        },
    };
}

fn construct_map_from_body(
    gpa: mem.Allocator,
    form: *Value,
    body: []const u8,
) !void {
    var pairs = mem.splitScalar(u8, body, '&');

    while (pairs.next()) |pair| {
        const field_idx = mem.findScalar(u8, pair, '=') orelse
            return error.MissingSeperator;
        if (pair.len < field_idx + 2) return error.MissingValue;

        const key = pair[0..field_idx];
        const value = pair[(field_idx + 1)..];

        if (mem.findScalar(u8, value, '=') != null)
            return error.MalformedPair;

        const decoded_key = try percentDecode(
            gpa,
            key,
        );
        errdefer gpa.free(decoded_key);

        const decoded_value = try percentDecode(
            gpa,
            value,
        );
        errdefer gpa.free(decoded_value);

        // Allow for duplicates (like with the URL params),
        // The last one just takes precedent.
        const entry = try form.getOrPut(
            gpa,
            decoded_key,
        );
        if (entry.found_existing) {
            gpa.free(decoded_key);
            gpa.free(entry.value_ptr.*);
        }
        entry.value_ptr.* = decoded_value;
    }
}

/// https://url.spec.whatwg.org/#percent-decode
/// Caller owns the returned memory and must free it
pub fn percentDecode(gpa: mem.Allocator, input: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = try .initCapacity(gpa, input.len);
    defer list.deinit(gpa);

    var input_index: usize = 0;
    while (input_index < input.len) : (input_index += 1) {
        const byte = input[input_index];
        switch (byte) {
            '%' => {
                const hex_bytes_size = 2;
                debug.assert(input_index + hex_bytes_size < input.len);

                const next_hex =
                    input[input_index + 1 ..][0..hex_bytes_size];

                switch (next_hex[0]) {
                    // 0...9, A...F, a...f
                    0x30...0x39, 0x41...0x46, 0x61...0x66 => {
                        switch (next_hex[1]) {
                            0x30...0x39, 0x41...0x46, 0x61...0x66 => {
                                const next_byte = try fmt.parseInt(
                                    u8,
                                    next_hex,
                                    16,
                                );
                                defer input_index += hex_bytes_size;

                                list.appendAssumeCapacity(next_byte);
                            },
                            else => {
                                list.appendAssumeCapacity(byte);
                            },
                        }
                    },
                    else => {
                        list.appendAssumeCapacity(byte);
                    },
                }
            },
            '+' => list.appendAssumeCapacity(' '),
            else => list.appendAssumeCapacity(byte),
        }
    }

    try list.shrinkToLen(gpa);

    return list.toOwnedSliceAssert();
}

test percentDecode {
    const gpa = testing.allocator;

    const inputs: [2]struct { []const u8, []const u8 } = .{
        .{ "%25%s%1G", "%%s%1G" },
        .{ "‽%25%2E", &.{ 0xE2, 0x80, 0xBD, 0x25, 0x2E } },
    };

    for (inputs) |tests_values| {
        const input, const expected = tests_values;
        const actual = try percentDecode(gpa, input);
        defer gpa.free(actual);

        try testing.expectEqualSlices(u8, expected[0..], actual);
    }
}

// https://datatracker.ietf.org/doc/html/rfc1866#section-8.2.1
// Casing not explicitly stated so keep key as-is
const Value = std.StringHashMapUnmanaged([]const u8);

test "FormData: Parsing from Body" {
    const UserRole = enum { admin, visitor };
    const User = struct { id: u32, name: []const u8, age: u8, role: UserRole };
    const body: []const u8 = "id=10&name=John&age=12&role=visitor";

    const gpa = testing.allocator;
    var form: Value = .empty;
    defer {
        var it = form.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        form.deinit(gpa);
    }
    try construct_map_from_body(gpa, &form, body);

    const parsed = try parse_struct(gpa, User, &form);
    defer gpa.free(parsed.name);

    try testing.expectEqual(10, parsed.id);
    try testing.expectEqualSlices(u8, "John", parsed.name);
    try testing.expectEqual(12, parsed.age);
    try testing.expectEqual(UserRole.visitor, parsed.role);
}

test "FormData: Parsing Missing Fields" {
    const User = struct { id: u32, name: []const u8, age: u8 };
    const body: []const u8 = "id=10";

    const gpa = testing.allocator;

    var form: Value = .empty;
    defer {
        var it = form.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        form.deinit(gpa);
    }

    try construct_map_from_body(gpa, &form, body);

    const parsed = parse_struct(gpa, User, &form);
    try testing.expectError(error.FieldEmpty, parsed);
}

test "FormData: Parsing Missing Value" {
    const body: []const u8 = "abc=abc&id=";

    const gpa = testing.allocator;
    var form: Value = .empty;
    defer {
        var it = form.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        form.deinit(gpa);
    }

    const result = construct_map_from_body(
        gpa,
        &form,
        body,
    );
    try testing.expectError(
        error.MissingValue,
        result,
    );
}

const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const debug = std.debug;
const testing = std.testing;

const zzz = @import("zzz");
const Context = @import("Context.zig");
