/// Parses Form data from a request body in `x-www-form-urlencoded` format.
pub fn Form(comptime T: type) type {
    return struct {
        pub fn parse(ctx: *const Context) !T {
            var form: UrlEncoded = .empty;
            form.deinit(ctx.arena);

            if (ctx.request.body) |body|
                try urlEncoded(ctx.arena, &form, body)
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
    form: *const UrlEncoded,
) !T {
    var ret: T = undefined;
    debug.assert(@typeInfo(T) == .@"struct");
    const struct_info = @typeInfo(T).@"struct";
    inline for (
        struct_info.field_types,
        struct_info.field_names,
        struct_info.field_attrs,
    ) |field_type, field_name, field_attrs| {
        const entry = form.map.getEntry(field_name);

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

/// https://url.spec.whatwg.org/#urlencoded-parsing
fn urlEncoded(
    gpa: mem.Allocator,
    form: *UrlEncoded,
    body: []const u8,
) !void {
    try form.urlDecoding(gpa, body);
}

// https://datatracker.ietf.org/doc/html/rfc1866#section-8.2.1
// Casing not explicitly stated so keep key as-is
const UrlEncoded = http.Queries;

test "FormData: Parsing from Body" {
    const gpa = testing.allocator;

    const UserRole = enum { admin, visitor };
    const User = struct { id: u32, name: []const u8, age: u8, role: UserRole };
    const body: []const u8 = "id=10&name=John&age=12&role=visitor";

    var form: UrlEncoded = .empty;
    defer form.deinit(gpa);

    try urlEncoded(gpa, &form, body);

    const parsed = try parse_struct(gpa, User, &form);
    defer gpa.free(parsed.name);

    try testing.expectEqual(10, parsed.id);
    try testing.expectEqualSlices(u8, "John", parsed.name);
    try testing.expectEqual(12, parsed.age);
    try testing.expectEqual(UserRole.visitor, parsed.role);
}

test "FormData: Parsing Missing Fields" {
    const gpa = testing.allocator;

    const User = struct { id: u32, name: []const u8, age: u8 };
    const body: []const u8 = "id=10";

    var form: UrlEncoded = .empty;
    defer form.deinit(gpa);

    try urlEncoded(gpa, &form, body);

    const parsed = parse_struct(gpa, User, &form);
    try testing.expectError(
        error.FieldEmpty,
        parsed,
    );
}

test "FormData: Parsing Missing Value" {
    const gpa = testing.allocator;

    var form: UrlEncoded = .empty;
    defer form.deinit(gpa);

    const body: []const u8 = "abc=abc&id=";

    const result = urlEncoded(
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
const http = zzz.http;
const Context = @import("Context.zig");
