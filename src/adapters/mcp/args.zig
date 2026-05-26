const std = @import("std");
const mcp = @import("mcp");

const manifest = @import("../../manifest/mod.zig");
const tool_errors = @import("errors.zig");
const tooling = @import("../../manifest/tooling.zig");

pub fn validateToolArgs(allocator: std.mem.Allocator, spec: manifest.ToolMeta, args: ?std.json.Value) mcp.tools.ToolError!?mcp.tools.ToolResult {
    const value = args orelse {
        for (spec.input_schema.fields) |field| {
            if (field[2]) {
                return try argumentErrorResult(allocator, spec.name, "missing_required_argument", field[0], field[1], "missing");
            }
        }
        return null;
    };

    const obj = switch (value) {
        .object => |object| object,
        else => return try argumentErrorResult(allocator, spec.name, "invalid_arguments", null, "object", jsonTypeName(value)),
    };

    var it = obj.iterator();
    while (it.next()) |entry| {
        const field = findSchemaField(spec.input_schema, entry.key_ptr.*) orelse {
            return try argumentErrorResult(allocator, spec.name, "unknown_argument", entry.key_ptr.*, "registered argument name", jsonTypeName(entry.value_ptr.*));
        };
        if (!schemaTypeMatches(field[1], entry.value_ptr.*)) {
            return try argumentErrorResult(allocator, spec.name, "invalid_type", field[0], field[1], jsonTypeName(entry.value_ptr.*));
        }
        if (try validateFieldHint(allocator, spec.name, spec.input_schema, field, entry.value_ptr.*)) |validation_error| return validation_error;
    }

    for (spec.input_schema.fields) |field| {
        if (field[2] and obj.get(field[0]) == null) {
            return try argumentErrorResult(allocator, spec.name, "missing_required_argument", field[0], field[1], "missing");
        }
    }

    return null;
}

pub fn findSchemaField(input_schema: tooling.SchemaSpec, name: []const u8) ?tooling.SchemaField {
    for (input_schema.fields) |field| {
        if (std.mem.eql(u8, field[0], name)) return field;
    }
    return null;
}

fn schemaTypeMatches(expected: []const u8, value: std.json.Value) bool {
    if (std.mem.eql(u8, expected, "string")) return value == .string;
    if (std.mem.eql(u8, expected, "boolean")) return value == .bool;
    if (std.mem.eql(u8, expected, "integer")) return value == .integer;
    return true;
}

fn validateFieldHint(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    input_schema: tooling.SchemaSpec,
    field: tooling.SchemaField,
    value: std.json.Value,
) mcp.tools.ToolError!?mcp.tools.ToolResult {
    const hint = tooling.hintFor(input_schema, field);
    switch (value) {
        .string => |actual| {
            if (hint.enum_values.len > 0 and !containsString(hint.enum_values, actual)) {
                const expected = enumExpectedString(allocator, hint.enum_values) catch return error.OutOfMemory;
                defer allocator.free(expected);
                return try argumentErrorResult(allocator, tool_name, "invalid_enum_value", field[0], expected, actual);
            }
        },
        .integer => |actual| {
            if (hint.minimum) |minimum| {
                if (actual < minimum) {
                    const expected = std.fmt.allocPrint(allocator, "integer >= {d}", .{minimum}) catch return error.OutOfMemory;
                    defer allocator.free(expected);
                    const actual_text = std.fmt.allocPrint(allocator, "{d}", .{actual}) catch return error.OutOfMemory;
                    defer allocator.free(actual_text);
                    return try argumentErrorResult(allocator, tool_name, "below_minimum", field[0], expected, actual_text);
                }
            }
            if (hint.maximum) |maximum| {
                if (actual > maximum) {
                    const expected = std.fmt.allocPrint(allocator, "integer <= {d}", .{maximum}) catch return error.OutOfMemory;
                    defer allocator.free(expected);
                    const actual_text = std.fmt.allocPrint(allocator, "{d}", .{actual}) catch return error.OutOfMemory;
                    defer allocator.free(actual_text);
                    return try argumentErrorResult(allocator, tool_name, "above_maximum", field[0], expected, actual_text);
                }
            }
        },
        else => {},
    }
    return null;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

fn enumExpectedString(allocator: std.mem.Allocator, values: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var out_owned = true;
    defer if (out_owned) out.deinit(allocator);
    try out.appendSlice(allocator, "one of: ");
    for (values, 0..) |value, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, value);
    }
    const bytes = try out.toOwnedSlice(allocator);
    out_owned = false;
    return bytes;
}

fn jsonTypeName(value: std.json.Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "boolean",
        .integer => "integer",
        .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
}

fn argumentErrorResult(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    code: []const u8,
    field: ?[]const u8,
    expected: []const u8,
    actual: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return tool_errors.argument(allocator, tool_name, code, field, expected, actual);
}

test "schema type matching accepts primitive types and unknown schema names" {
    try std.testing.expect(schemaTypeMatches("string", .{ .string = "text" }));
    try std.testing.expect(schemaTypeMatches("boolean", .{ .bool = true }));
    try std.testing.expect(schemaTypeMatches("integer", .{ .integer = 1 }));
    try std.testing.expect(schemaTypeMatches("custom", .null));
}
