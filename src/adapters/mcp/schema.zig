const std = @import("std");
const mcp = @import("mcp");

const tooling = @import("../../manifest/tooling.zig");

pub fn buildInputSchema(allocator: std.mem.Allocator, spec: tooling.SchemaSpec) !mcp.types.InputSchema {
    var properties = std.json.ObjectMap.empty;
    var required = std.ArrayList([]const u8).empty;
    errdefer {
        properties.deinit(allocator);
        required.deinit(allocator);
    }

    for (spec.fields) |field| {
        var property = std.json.ObjectMap.empty;
        errdefer property.deinit(allocator);
        try property.put(allocator, "type", .{ .string = field[1] });
        try applyFieldHint(allocator, &property, spec, field);
        try properties.put(allocator, field[0], .{ .object = property });
        if (field[2]) try required.append(allocator, field[0]);
    }

    const required_slice = if (required.items.len > 0)
        try required.toOwnedSlice(allocator)
    else
        null;

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
        errdefer values.deinit();
        for (hint.enum_values) |value| try values.append(.{ .string = value });
        try property.put(allocator, "enum", .{ .array = values });
    }
}

test "input schema includes discovery hints" {
    var s = try buildInputSchema(std.testing.allocator, tooling.schema(&.{
        .{ "file", "string", true },
        .{ "apply", "boolean", false },
    }));
    defer if (s.required) |required| std.testing.allocator.free(required);
    defer if (s.properties) |*properties| {
        var it = properties.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.object.get("enum")) |*value| value.array.deinit();
            entry.value_ptr.object.deinit(std.testing.allocator);
        }
        properties.object.deinit(std.testing.allocator);
    };
    const file = s.properties.?.object.get("file").?.object;
    try std.testing.expectEqualStrings("Workspace-relative source file path.", file.get("description").?.string);
    try std.testing.expectEqualStrings("input_file", file.get("x-zigar-path-kind").?.string);
    const apply = s.properties.?.object.get("apply").?.object;
    try std.testing.expect(!apply.get("default").?.bool);
}
