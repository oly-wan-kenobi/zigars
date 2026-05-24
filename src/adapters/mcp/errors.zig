const std = @import("std");
const mcp = @import("mcp");

const mcp_result = @import("result.zig");

pub const Detail = struct {
    key: []const u8,
    value: std.json.Value,
};

pub const Spec = struct {
    kind: []const u8 = "tool_error",
    tool: []const u8,
    operation: []const u8,
    phase: []const u8,
    code: []const u8,
    category: []const u8,
    retryable: bool = false,
    cause: ?[]const u8 = null,
    resolution: []const u8,
    details: []const Detail = &.{},
};

pub fn result(allocator: std.mem.Allocator, spec: Spec) mcp.tools.ToolError!mcp.tools.ToolResult {
    var err_value = value(allocator, spec) catch return error.OutOfMemory;
    defer deinitTopLevel(allocator, &err_value);
    return mcp_result.structuredError(allocator, err_value);
}

pub fn fromError(allocator: std.mem.Allocator, spec: Spec, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    var err_value = valueFromError(allocator, spec, err) catch return error.OutOfMemory;
    defer deinitTopLevel(allocator, &err_value);
    return mcp_result.structuredError(allocator, err_value);
}

pub fn value(allocator: std.mem.Allocator, spec: Spec) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = spec.kind });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "tool", .{ .string = spec.tool });
    try obj.put(allocator, "operation", .{ .string = spec.operation });
    try obj.put(allocator, "phase", .{ .string = spec.phase });
    try obj.put(allocator, "code", .{ .string = spec.code });
    try obj.put(allocator, "category", .{ .string = spec.category });
    try obj.put(allocator, "retryable", .{ .bool = spec.retryable });
    if (spec.cause) |cause| try obj.put(allocator, "cause", .{ .string = cause });
    try obj.put(allocator, "resolution", .{ .string = spec.resolution });
    for (spec.details) |detail| try obj.put(allocator, detail.key, detail.value);
    return .{ .object = obj };
}

pub fn valueFromError(allocator: std.mem.Allocator, spec: Spec, err: anyerror) !std.json.Value {
    var result_value = try value(allocator, spec);
    try result_value.object.put(allocator, "error", .{ .string = @errorName(err) });
    try result_value.object.put(allocator, "error_kind", .{ .string = kindForError(err) });
    return result_value;
}

pub fn argument(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    code: []const u8,
    field: ?[]const u8,
    expected: []const u8,
    actual: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return result(allocator, .{
        .kind = "argument_error",
        .tool = tool_name,
        .operation = "parse_arguments",
        .phase = "validate_argument",
        .code = code,
        .category = "argument",
        .resolution = "Inspect the tools/list inputSchema or zigar_schema catalog, then retry with the registered argument names and JSON types.",
        .details = &.{
            .{ .key = "field", .value = if (field) |name| .{ .string = name } else .null },
            .{ .key = "expected", .value = .{ .string = expected } },
            .{ .key = "actual", .value = .{ .string = actual } },
        },
    });
}

pub fn missingArgument(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, expected: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return argument(allocator, tool_name, "missing_required_argument", field, expected, "missing");
}

pub fn invalidArgument(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    field: ?[]const u8,
    expected: []const u8,
    actual: []const u8,
    resolution: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return result(allocator, .{
        .kind = "argument_error",
        .tool = tool_name,
        .operation = "parse_arguments",
        .phase = "validate_argument",
        .code = "invalid_argument",
        .category = "argument",
        .resolution = resolution,
        .details = &.{
            .{ .key = "field", .value = if (field) |name| .{ .string = name } else .null },
            .{ .key = "expected", .value = .{ .string = expected } },
            .{ .key = "actual", .value = .{ .string = actual } },
        },
    });
}

fn deinitTopLevel(allocator: std.mem.Allocator, result_value: *std.json.Value) void {
    switch (result_value.*) {
        .object => |*obj| obj.deinit(allocator),
        else => {},
    }
}

pub fn workspacePath(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    path: []const u8,
    workspace: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return result(allocator, .{
        .kind = "workspace_path_error",
        .tool = tool_name,
        .operation = "resolve_workspace_path",
        .phase = if (err == error.EmptyPath) "validate_path" else "workspace_boundary",
        .code = if (err == error.EmptyPath) "empty_path" else "path_outside_workspace",
        .category = "workspace_path",
        .resolution = "Run zigar_workspace_info to confirm the active workspace, then retry with a workspace-relative path inside that root.",
        .details = &.{
            .{ .key = "path", .value = .{ .string = path } },
            .{ .key = "workspace", .value = .{ .string = workspace } },
            .{ .key = "error", .value = .{ .string = @errorName(err) } },
            .{ .key = "error_kind", .value = .{ .string = "workspace_path" } },
        },
    });
}

pub fn kindForError(err: anyerror) []const u8 {
    return switch (err) {
        error.RequestTimeout, error.Timeout => "timeout",
        error.NotConnected, error.EndOfStream, error.BrokenPipe => "unavailable",
        error.FileNotFound, error.ResourceNotFound => "not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        error.StreamTooLong => "output_limit",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        error.DocumentTooLarge, error.OpenDocumentLimitExceeded, error.RetainedContentLimitExceeded => "document_state_limit",
        error.InvalidArguments, error.InvalidTextEdit => "invalid_data",
        else => "execution_failed",
    };
}

test "tool error value includes stable contract fields" {
    const err_value = try value(std.testing.allocator, .{
        .tool = "zig_format",
        .operation = "format_preview",
        .phase = "read_source",
        .code = "read_failed",
        .category = "filesystem",
        .resolution = "retry with a readable workspace file",
        .details = &.{.{ .key = "file", .value = .{ .string = "src/main.zig" } }},
    });
    var value_copy = err_value;
    defer value_copy.object.deinit(std.testing.allocator);

    const obj = err_value.object;
    try std.testing.expectEqualStrings("tool_error", obj.get("kind").?.string);
    try std.testing.expect(!obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("zig_format", obj.get("tool").?.string);
    try std.testing.expectEqualStrings("format_preview", obj.get("operation").?.string);
    try std.testing.expectEqualStrings("read_source", obj.get("phase").?.string);
    try std.testing.expectEqualStrings("read_failed", obj.get("code").?.string);
    try std.testing.expectEqualStrings("filesystem", obj.get("category").?.string);
    try std.testing.expectEqualStrings("src/main.zig", obj.get("file").?.string);
}

test "tool error result is marked as an MCP error with structured content" {
    const allocator = std.testing.allocator;
    const tool_result = try missingArgument(allocator, "zig_format", "file", "string");
    defer mcp_result.deinitToolResult(allocator, tool_result);

    try std.testing.expect(tool_result.is_error);
    const obj = tool_result.structuredContent.?.object;
    try std.testing.expectEqualStrings("argument_error", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("zig_format", obj.get("tool").?.string);
    try std.testing.expectEqualStrings("file", obj.get("field").?.string);
}
