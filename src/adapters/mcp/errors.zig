//! Structured MCP tool-error shaping with stable machine-readable metadata fields.
const std = @import("std");
const mcp = @import("mcp");

const mcp_result = @import("result.zig");

/// Additional JSON fields copied into a structured error object.
pub const Detail = struct {
    key: []const u8,
    value: std.json.Value,
};

/// Stable MCP error envelope fields shared across adapter failures.
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

/// Builds a ToolResult flagged as an error; returned JSON is allocator-owned by caller.
pub fn result(allocator: std.mem.Allocator, spec: Spec) mcp.tools.ToolError!mcp.tools.ToolResult {
    var err_value = value(allocator, spec) catch return error.OutOfMemory;
    defer deinitTopLevel(allocator, &err_value);
    return mcp_result.structuredError(allocator, err_value);
}

/// Builds a structured ToolResult and adds normalized Zig error metadata.
pub fn fromError(allocator: std.mem.Allocator, spec: Spec, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    var err_value = valueFromError(allocator, spec, err) catch return error.OutOfMemory;
    defer deinitTopLevel(allocator, &err_value);
    return mcp_result.structuredError(allocator, err_value);
}

/// Builds the JSON error object owned by `allocator`; the string fields borrow
/// from `spec`, so `spec` must outlive the returned value. The fixed `ok:false`
/// field lets clients branch on success without parsing the error envelope.
pub fn value(allocator: std.mem.Allocator, spec: Spec) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    // Free the partial object on any early `put` failure; cleared once the fully
    // built object is handed to the caller.
    var obj_in_result = false;
    defer if (!obj_in_result) obj.deinit(allocator);
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
    obj_in_result = true;
    return .{ .object = obj };
}

/// Extends `value` with error name and normalized error_kind fields.
pub fn valueFromError(allocator: std.mem.Allocator, spec: Spec, err: anyerror) !std.json.Value {
    var result_value = try value(allocator, spec);
    try result_value.object.put(allocator, "error", .{ .string = @errorName(err) });
    try result_value.object.put(allocator, "error_kind", .{ .string = kindForError(err) });
    return result_value;
}

/// Like `valueFromError` but omits the raw `@errorName`, exposing only the
/// coarsened, protocol-stable `error_kind`. Used by the server's tool/resource/
/// prompt handler `anyerror` fallbacks so an unexpected internal Zig error name
/// never reaches client-visible content/structuredContent (LOW-1); the raw name
/// stays in the stderr log only.
pub fn valueFromErrorKindOnly(allocator: std.mem.Allocator, spec: Spec, err: anyerror) !std.json.Value {
    var result_value = try value(allocator, spec);
    try result_value.object.put(allocator, "error_kind", .{ .string = kindForError(err) });
    return result_value;
}

/// Builds a structured argument-validation failure.
pub fn argument(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    code: []const u8,
    field: ?[]const u8,
    expected: []const u8,
    actual: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return result(allocator, .{
        .kind = "argument_error",
        .tool = tool_name,
        .operation = "parse_arguments",
        .phase = "validate_argument",
        .code = code,
        .category = "argument",
        .resolution = "Inspect the tools/list inputSchema or zigars_schema catalog, then retry with the registered argument names and JSON types.",
        .details = &.{
            .{ .key = "field", .value = if (field) |name| .{ .string = name } else .null },
            .{ .key = "expected", .value = .{ .string = expected } },
            .{ .key = "actual", .value = .{ .string = actual } },
        },
    });
}

/// Convenience wrapper for required fields absent from JSON args.
pub fn missingArgument(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, expected: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return argument(allocator, tool_name, "missing_required_argument", field, expected, "missing");
}

/// Convenience wrapper for present fields with invalid values.
pub fn invalidArgument(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    field: ?[]const u8,
    expected: []const u8,
    actual: []const u8,
    resolution: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Frees the top-level JSON container allocated for a structured error payload.
fn deinitTopLevel(allocator: std.mem.Allocator, result_value: *std.json.Value) void {
    switch (result_value.*) {
        .object => |*obj| obj.deinit(allocator),
        else => {},
    }
}

/// Maps workspace path-policy failures into a stable MCP error envelope.
/// Distinguishes an empty path (rejected during validation) from a path that
/// escapes the sandbox (rejected at the boundary) so clients can tell a typo
/// from an attempted traversal; the resolved `workspace` root is echoed back to
/// orient the caller. Every other anyerror is treated as a boundary rejection.
pub fn workspacePath(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    path: []const u8,
    workspace: []const u8,
    err: anyerror,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    // Normalize and constrain path handling here before any downstream filesystem action.
    return result(allocator, .{
        .kind = "workspace_path_error",
        .tool = tool_name,
        .operation = "resolve_workspace_path",
        .phase = if (err == error.EmptyPath) "validate_path" else "workspace_boundary",
        .code = if (err == error.EmptyPath) "empty_path" else "path_outside_workspace",
        .category = "workspace_path",
        .resolution = "Run zigars_workspace_info to confirm the active workspace, then retry with a workspace-relative path inside that root.",
        .details = &.{
            .{ .key = "path", .value = .{ .string = path } },
            .{ .key = "workspace", .value = .{ .string = workspace } },
            .{ .key = "error", .value = .{ .string = @errorName(err) } },
            .{ .key = "error_kind", .value = .{ .string = "workspace_path" } },
        },
    });
}

/// Coarsens any Zig error into one of a small set of protocol-stable category
/// strings. Clients should branch on these rather than on raw `@errorName`,
/// which can change as std and backend error sets evolve. Unmapped errors fall
/// back to "execution_failed".
pub fn kindForError(err: anyerror) []const u8 {
    // Preserve a single error-shaping path so callers receive consistent metadata.
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
