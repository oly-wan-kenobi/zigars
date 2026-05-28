//! MCP discovery-tool adapter that projects discovery use-case outputs into
//! stable tool contracts and centralized structured error envelopes.
const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const discovery = @import("../../../app/usecases/discovery/workflows.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

/// Handles MCP `zigars_capabilities` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsCapabilities(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return catalogStructured(allocator, "zigars_capabilities", discovery.catalogText(allocator, context) catch return error.OutOfMemory);
}

/// Handles MCP `zigars_schema` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsSchema(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return catalogStructured(allocator, "zigars_schema", discovery.catalogText(allocator, context) catch return error.OutOfMemory);
}

/// Handles MCP `zigars_backend_catalog` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsBackendCatalog(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, discovery.backendCatalogValue(allocator, context, argBool(args, "include_configured_paths", true)) catch return error.OutOfMemory);
}

/// Handles MCP `zigars_doctor` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsDoctor(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const probe_backends = argBool(args, "probe_backends", false);
    const probe_timeout_ms = @max(1, @min(argInt(args, "timeout_ms", 1_000), 10_000));
    return structured(allocator, discovery.doctorValue(allocator, context, probe_backends, probe_timeout_ms) catch return error.OutOfMemory);
}

/// Handles MCP `workspace_info` requests by delegating to app logic and shaping owned results/errors.
pub fn workspaceInfo(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, discovery.workspaceInfoValue(allocator, context) catch return error.OutOfMemory);
}

/// Handles MCP `zigars_metrics` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsMetrics(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, discovery.metricsValue(allocator, context) catch return error.OutOfMemory);
}

/// Handles MCP `zigars_http_status` requests by delegating to app logic and shaping owned results/errors.
pub fn zigarsHttpStatus(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, discovery.httpStatusValue(allocator, context) catch return error.OutOfMemory);
}

/// Handles MCP `zig_toolchain_resolve` requests by delegating to app logic and shaping owned results/errors.
pub fn zigToolchainResolve(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const timeout_ms = @max(1, @min(argInt(args, "timeout_ms", context.timeouts.command_ms), 60 * 60 * 1000));
    const value = discovery.toolchainResolveValue(allocator, context, argBool(args, "probe_managers", false), timeout_ms) catch |err| return portToolError(allocator, "zig_toolchain_resolve", "resolve_toolchain", err);
    return structured(allocator, value);
}

/// Handles MCP `zig_command_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCommandPlan(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const value = discovery.commandPlanValue(allocator, context, planRequest(context, args)) catch |err| return planError(allocator, "zig_command_plan", args, err);
    return structured(allocator, value);
}

/// Handles MCP `zig_tool_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigToolPlan(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const value = discovery.toolPlanValue(allocator, context, planRequest(context, args)) catch |err| return planError(allocator, "zig_tool_plan", args, err);
    return structured(allocator, value);
}

/// Wraps a JSON value as a structured MCP tool result.
fn structured(allocator: std.mem.Allocator, value: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_result.structured(allocator, value);
}

/// Parses catalog JSON and returns both structuredContent and a text fallback.
fn catalogStructured(allocator: std.mem.Allocator, tool_name: []const u8, bytes: []u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return mcp_errors.fromError(allocator, .{
            .tool = tool_name,
            .operation = "parse_catalog",
            .phase = "discovery_usecase",
            .code = "catalog_parse_failed",
            .category = "discovery",
            .resolution = "Retry after regenerating the tool catalog with zigars release and docs checks.",
        }, err);
    };
    defer parsed.deinit();
    return structured(allocator, parsed.value);
}

/// Parse permissive JSON args and clamp timeout at the adapter boundary so
/// downstream planning code receives normalized request values.
fn planRequest(context: app_context.Context, args: ?std.json.Value) discovery.PlanRequest {
    return .{
        .tool = argString(args, "tool"),
        .file = argString(args, "file"),
        .path = argString(args, "path"),
        .args = argString(args, "args") orelse "",
        .timeout_ms = @max(1, @min(argInt(args, "timeout_ms", context.timeouts.command_ms), 60 * 60 * 1000)),
    };
}

/// Map discovery/use-case failures to protocol-stable MCP error codes.
fn planError(allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.MissingTool => mcp_errors.missingArgument(allocator, tool_name, "tool", "registered tool name"),
        error.UnknownTool => mcp_errors.invalidArgument(allocator, tool_name, "tool", "registered tool name", argString(args, "tool") orelse "", "Call zigars_capabilities or zigars_schema to inspect the registered tool names, then retry with one of those names."),
        error.MissingFile => missingPlanningArgument(allocator, tool_name, "file"),
        error.MissingPath => missingPlanningArgument(allocator, tool_name, "path"),
        error.InvalidExtraArgs => mcp_errors.invalidArgument(allocator, tool_name, "args", "shell-style argument string", argString(args, "args") orelse "", "Quote arguments the same way you would in a shell command, or omit the field when no extra arguments are needed."),
        error.PathOutsideWorkspace, error.EmptyPath => mcp_errors.workspacePath(allocator, tool_name, argString(args, "file") orelse argString(args, "path") orelse "", "", err),
        error.MissingPort => portToolError(allocator, tool_name, "build_app_context", err),
        else => portToolError(allocator, tool_name, "plan_tool", err),
    };
}

/// Returns the structured missing-argument error for environment planning tools.
fn missingPlanningArgument(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.result(allocator, .{
        .kind = "tool_error",
        .tool = tool_name,
        .operation = tool_name,
        .phase = "validate_argument",
        .code = "missing_required_argument",
        .category = "argument",
        .resolution = "Provide the required argument or use zig_tool_plan on non-command tools to inspect planning support without producing argv.",
        .details = &.{
            .{ .key = "error_kind", .value = .{ .string = "argument_error" } },
            .{ .key = "field", .value = .{ .string = field } },
            .{ .key = "expected", .value = .{ .string = "non-empty workspace-relative path" } },
        },
    });
}

/// Maps port tool error failures to structured MCP errors.
fn portToolError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "discovery_usecase",
        .code = "discovery_failed",
        .category = "discovery",
        .resolution = "Retry after confirming workspace, configured backend paths, and runtime ports with zigars_doctor.",
    }, err);
}

/// Reads a string argument when it is present with the expected type.
fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    const obj = switch (args orelse return null) {
        .object => |o| o,
        else => return null,
    };
    return switch (obj.get(name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Reads a bool argument when it is present with the expected type.
fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    const obj = switch (args orelse return default) {
        .object => |o| o,
        else => return default,
    };
    return switch (obj.get(name) orelse return default) {
        .bool => |b| b,
        else => default,
    };
}

/// Reads an int argument when it is present with the expected type.
fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    const obj = switch (args orelse return default) {
        .object => |o| o,
        else => return default,
    };
    return switch (obj.get(name) orelse return default) {
        .integer => |i| i,
        else => default,
    };
}

test "discovery adapter planning errors map to structured MCP errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "tool", .{ .string = "missing_tool" });
    try args.put(allocator, "file", .{ .string = "../escape.zig" });
    try args.put(allocator, "path", .{ .string = "" });
    try args.put(allocator, "args", .{ .string = "\"unterminated" });
    const args_value: std.json.Value = .{ .object = args };

    // Each assertion locks the external code mapping for a distinct failure
    // class so clients can branch without parsing human-readable text.
    const missing_tool = try planError(allocator, "zig_command_plan", null, error.MissingTool);
    try expectToolErrorCode(missing_tool, "missing_required_argument");

    const unknown_tool = try planError(allocator, "zig_command_plan", args_value, error.UnknownTool);
    try expectToolErrorCode(unknown_tool, "invalid_argument");

    const missing_file = try planError(allocator, "zig_command_plan", args_value, error.MissingFile);
    try expectToolErrorCode(missing_file, "missing_required_argument");

    const missing_path = try planError(allocator, "zig_tool_plan", args_value, error.MissingPath);
    try expectToolErrorCode(missing_path, "missing_required_argument");

    const invalid_extra = try planError(allocator, "zig_command_plan", args_value, error.InvalidExtraArgs);
    try expectToolErrorCode(invalid_extra, "invalid_argument");

    const outside = try planError(allocator, "zig_command_plan", args_value, error.PathOutsideWorkspace);
    try expectToolErrorCode(outside, "path_outside_workspace");

    const empty = try planError(allocator, "zig_tool_plan", args_value, error.EmptyPath);
    try expectToolErrorCode(empty, "empty_path");

    const missing_port = try planError(allocator, "zig_tool_plan", args_value, error.MissingPort);
    try expectToolErrorCode(missing_port, "discovery_failed");

    const denied = try planError(allocator, "zig_tool_plan", args_value, error.AccessDenied);
    try expectToolErrorCode(denied, "discovery_failed");
}

/// Maps expect tool error code failures to structured MCP errors.
fn expectToolErrorCode(result: mcp.tools.ToolResult, expected: []const u8) !void {
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings(expected, result.structuredContent.?.object.get("code").?.string);
}
