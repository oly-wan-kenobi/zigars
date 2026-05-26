const std = @import("std");
const mcp = @import("mcp");

const tooling = @import("../../manifest/tooling.zig");

pub fn buildInputSchema(allocator: std.mem.Allocator, spec: tooling.SchemaSpec) !mcp.types.InputSchema {
    var properties = std.json.ObjectMap.empty;
    var required = std.ArrayList([]const u8).empty;
    var schema_owned = true;
    defer if (schema_owned) required.deinit(allocator);
    defer if (schema_owned) properties.deinit(allocator);

    for (spec.fields) |field| {
        var property = std.json.ObjectMap.empty;
        var property_owned = true;
        defer if (property_owned) property.deinit(allocator);
        try property.put(allocator, "type", .{ .string = field[1] });
        try applyFieldHint(allocator, &property, spec, field);
        try properties.put(allocator, field[0], .{ .object = property });
        property_owned = false;
        if (field[2]) try required.append(allocator, field[0]);
    }

    const required_slice = if (required.items.len > 0)
        try required.toOwnedSlice(allocator)
    else
        null;

    schema_owned = false;
    return .{
        .properties = .{ .object = properties },
        .required = required_slice,
    };
}

fn applyFieldHint(
    allocator: std.mem.Allocator,
    property: *std.json.ObjectMap,
    spec: tooling.SchemaSpec,
    field: tooling.SchemaField,
) !void {
    const hint = tooling.hintFor(spec, field);
    try property.put(allocator, "description", .{ .string = hint.description });
    if (hint.default_bool) |value| try property.put(allocator, "default", .{ .bool = value });
    if (hint.default_int) |value| try property.put(allocator, "default", .{ .integer = value });
    if (hint.default_string) |value| try property.put(allocator, "default", .{ .string = value });
    if (hint.path_kind) |value| try property.put(allocator, "x-zigar-path-kind", .{ .string = value });
    if (hint.minimum) |value| try property.put(allocator, "minimum", .{ .integer = value });
    if (hint.maximum) |value| try property.put(allocator, "maximum", .{ .integer = value });
    if (hint.enum_values.len > 0) {
        var values = std.json.Array.init(allocator);
        var values_owned = true;
        defer if (values_owned) values.deinit();
        for (hint.enum_values) |value| try values.append(.{ .string = value });
        try property.put(allocator, "enum", .{ .array = values });
        values_owned = false;
    }
}
