const std = @import("std");
const mcp = @import("mcp");

const json_result = @import("json_result.zig");
const mcp_server = @import("mcp_server.zig");
const runtime_mod = @import("runtime.zig");
const tool_errors = @import("tool_errors.zig");
const tool_metadata = @import("tool_metadata.zig");
const tooling = @import("tooling.zig");

const SchemaSpec = tooling.SchemaSpec;

const App = runtime_mod.App;

pub const ToolHandler = tool_metadata.ToolHandler;

pub fn addTool(
    server: *mcp_server.Server,
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
            .readOnlyHint = tool_metadata.readOnlyHintFor(spec),
            .idempotentHint = tool_metadata.idempotentHintFor(spec),
            .destructiveHint = tool_metadata.destructiveHintFor(spec),
            .openWorldHint = false,
        },
        .handler = mcpHandler(spec, handler),
        .deinit_result = json_result.deinitToolResult,
        .user_data = runtime,
    });
}

fn mcpHandler(comptime spec: tool_metadata.ToolMeta, comptime handler: ToolHandler) *const fn (?*anyopaque, std.Io, std.mem.Allocator, ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return struct {
        fn call(user_data: ?*anyopaque, io: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
            const runtime: *App = @ptrCast(@alignCast(user_data orelse return tool_errors.result(allocator, .{
                .tool = spec.name,
                .operation = "dispatch_tool",
                .phase = "runtime_lookup",
                .code = "runtime_unavailable",
                .category = "server_state",
                .resolution = "Restart zigar; the MCP server registered this tool without attaching runtime state.",
            })));
            const started_ns = std.Io.Clock.now(.real, io).nanoseconds;
            if (try validateToolArgs(allocator, spec, args)) |validation_error| {
                runtime.observability.recordToolCall(spec.name, elapsedMs(io, started_ns), validation_error.is_error);
                return validation_error;
            }
            const result = handler(runtime, allocator, args) catch |err| {
                runtime.observability.recordToolCall(spec.name, elapsedMs(io, started_ns), true);
                return err;
            };
            runtime.observability.recordToolCall(spec.name, elapsedMs(io, started_ns), result.is_error);
            return result;
        }
    }.call;
}

fn elapsedMs(io: std.Io, started_ns: anytype) u64 {
    const duration_ns = std.Io.Clock.now(.real, io).nanoseconds - started_ns;
    if (duration_ns <= 0) return 0;
    return @intCast(@divTrunc(duration_ns, std.time.ns_per_ms));
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
        if (try validateFieldHint(allocator, spec.name, spec.input_schema, field, entry.value_ptr.*)) |validation_error| return validation_error;
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
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "one of: ");
    for (values, 0..) |value, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, value);
    }
    return out.toOwnedSlice(allocator);
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

test "rejects enum arguments outside schema hints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spec = tool_metadata.find("zigar_context_pack").?;

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "mode", .{ .string = "sideways" });
    const result = (try validateToolArgs(allocator, spec, .{ .object = obj })).?;
    const err = result.structuredContent.?.object;

    try std.testing.expectEqualStrings("argument_error", err.get("kind").?.string);
    try std.testing.expectEqualStrings("invalid_enum_value", err.get("code").?.string);
    try std.testing.expectEqualStrings("mode", err.get("field").?.string);
    try std.testing.expect(std.mem.indexOf(u8, err.get("expected").?.string, "standard") != null);
    try std.testing.expectEqualStrings("sideways", err.get("actual").?.string);
}

test "validates enum hints in tool context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const context_spec = tool_metadata.find("zigar_context_pack").?;
    const validate_spec = tool_metadata.find("zigar_validate_patch").?;

    var context_obj = std.json.ObjectMap.empty;
    try context_obj.put(allocator, "mode", .{ .string = "quick" });
    const context_result = (try validateToolArgs(allocator, context_spec, .{ .object = context_obj })).?;
    const context_err = context_result.structuredContent.?.object;
    try std.testing.expectEqualStrings("invalid_enum_value", context_err.get("code").?.string);
    try std.testing.expect(std.mem.indexOf(u8, context_err.get("expected").?.string, "deep") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_err.get("expected").?.string, "quick") == null);

    var validate_obj = std.json.ObjectMap.empty;
    try validate_obj.put(allocator, "mode", .{ .string = "quick" });
    try std.testing.expect((try validateToolArgs(allocator, validate_spec, .{ .object = validate_obj })) == null);

    var invalid_validate_obj = std.json.ObjectMap.empty;
    try invalid_validate_obj.put(allocator, "mode", .{ .string = "deep" });
    const validate_result = (try validateToolArgs(allocator, validate_spec, .{ .object = invalid_validate_obj })).?;
    const validate_err = validate_result.structuredContent.?.object;
    try std.testing.expectEqualStrings("invalid_enum_value", validate_err.get("code").?.string);
    try std.testing.expect(std.mem.indexOf(u8, validate_err.get("expected").?.string, "quick") != null);
    try std.testing.expect(std.mem.indexOf(u8, validate_err.get("expected").?.string, "deep") == null);
}

test "rejects integer arguments below schema minimum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spec = tool_metadata.find("zig_std_search").?;

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "query", .{ .string = "ArrayList" });
    try obj.put(allocator, "limit", .{ .integer = 0 });
    const result = (try validateToolArgs(allocator, spec, .{ .object = obj })).?;
    const err = result.structuredContent.?.object;

    try std.testing.expectEqualStrings("argument_error", err.get("kind").?.string);
    try std.testing.expectEqualStrings("below_minimum", err.get("code").?.string);
    try std.testing.expectEqualStrings("limit", err.get("field").?.string);
    try std.testing.expectEqualStrings("integer >= 1", err.get("expected").?.string);
    try std.testing.expectEqualStrings("0", err.get("actual").?.string);
}
