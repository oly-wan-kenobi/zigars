const std = @import("std");
const mcp = @import("mcp");

const json_result = @import("json_result.zig");
const runtime_mod = @import("runtime.zig");
const tool_metadata = @import("tool_metadata.zig");
const tooling = @import("tooling.zig");

const SchemaSpec = tooling.SchemaSpec;

const App = runtime_mod.App;

pub const ToolHandler = *const fn (*App, std.mem.Allocator, ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult;

pub fn addTool(
    server: *mcp.Server,
    allocator: std.mem.Allocator,
    runtime: *App,
    comptime spec: tool_metadata.ToolMeta,
    comptime handler: ToolHandler,
) !void {
    const schema_value = try tooling.buildInputSchema(allocator, spec.input_schema);
    try server.addTool(.{
        .name = spec.name,
        .description = spec.description,
        .title = spec.name,
        .inputSchema = schema_value,
        .annotations = .{
            .readOnlyHint = spec.read_only,
            .idempotentHint = spec.read_only,
            .destructiveHint = tool_metadata.destructiveHintFor(spec),
            .openWorldHint = false,
        },
        .handler = mcpHandler(spec, handler),
        .user_data = runtime,
    });
}

fn mcpHandler(comptime spec: tool_metadata.ToolMeta, comptime handler: ToolHandler) *const fn (?*anyopaque, std.Io, std.mem.Allocator, ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return struct {
        fn call(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
            const runtime: *App = @ptrCast(@alignCast(user_data orelse return error.ExecutionFailed));
            if (try validateToolArgs(allocator, spec, args)) |validation_error| return validation_error;
            return handler(runtime, allocator, args);
        }
    }.call;
}

pub fn validateToolArgs(allocator: std.mem.Allocator, spec: tool_metadata.ToolMeta, args: ?std.json.Value) mcp.tools.ToolError!?mcp.tools.ToolResult {
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
    }

    for (spec.input_schema.fields) |field| {
        if (field[2] and obj.get(field[0]) == null) {
            return try argumentErrorResult(allocator, spec.name, "missing_required_argument", field[0], field[1], "missing");
        }
    }

    return null;
}

fn findSchemaField(input_schema: SchemaSpec, name: []const u8) ?tooling.SchemaField {
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
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "argument_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "tool", .{ .string = tool_name });
    try obj.put(allocator, "code", .{ .string = code });
    if (field) |field_name| {
        try obj.put(allocator, "field", .{ .string = field_name });
    } else {
        try obj.put(allocator, "field", .null);
    }
    try obj.put(allocator, "expected", .{ .string = expected });
    try obj.put(allocator, "actual", .{ .string = actual });
    try obj.put(allocator, "resolution", .{ .string = "Call zigar_schema for compact argument hints, then retry with the registered argument names and JSON types." });
    return json_result.structured(allocator, .{ .object = obj });
}

test "finds schema fields" {
    const spec = tool_metadata.find("zig_check").?;
    const field = findSchemaField(spec.input_schema, "file").?;
    try std.testing.expect(field[2]);
    try std.testing.expectEqualStrings("string", field[1]);
}

test "accepts empty argument object for no-argument tool" {
    const spec = tool_metadata.find("zig_version").?;
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(std.testing.allocator);
    const result = try validateToolArgs(std.testing.allocator, spec, .{ .object = obj });
    try std.testing.expect(result == null);
}
