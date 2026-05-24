const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const discovery = @import("../../../app/usecases/discovery/workflows.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

pub fn zigarCapabilities(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return jsonTextOnly(allocator, discovery.catalogText(allocator, context) catch return error.OutOfMemory);
}

pub fn zigarSchema(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return jsonTextOnly(allocator, discovery.catalogText(allocator, context) catch return error.OutOfMemory);
}

pub fn zigarBackendCatalog(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, discovery.backendCatalogValue(allocator, context, argBool(args, "include_configured_paths", true)) catch return error.OutOfMemory);
}

pub fn zigarDoctor(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const probe_backends = argBool(args, "probe_backends", false);
    const probe_timeout_ms = @max(1, @min(argInt(args, "timeout_ms", 1_000), 10_000));
    return structured(allocator, discovery.doctorValue(allocator, context, probe_backends, probe_timeout_ms) catch return error.OutOfMemory);
}

pub fn workspaceInfo(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, discovery.workspaceInfoValue(allocator, context) catch return error.OutOfMemory);
}

pub fn zigarMetrics(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, discovery.metricsValue(allocator, context) catch return error.OutOfMemory);
}

pub fn zigarHttpStatus(allocator: std.mem.Allocator, context: app_context.Context, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, discovery.httpStatusValue(allocator, context) catch return error.OutOfMemory);
}

pub fn zigToolchainResolve(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const timeout_ms = @max(1, @min(argInt(args, "timeout_ms", context.timeouts.command_ms), 60 * 60 * 1000));
    const value = discovery.toolchainResolveValue(allocator, context, argBool(args, "probe_managers", false), timeout_ms) catch |err| return portToolError(allocator, "zig_toolchain_resolve", "resolve_toolchain", err);
    return structured(allocator, value);
}

pub fn zigCommandPlan(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const value = discovery.commandPlanValue(allocator, context, planRequest(context, args)) catch |err| return planError(allocator, "zig_command_plan", args, err);
    return structured(allocator, value);
}

pub fn zigToolPlan(allocator: std.mem.Allocator, context: app_context.Context, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const value = discovery.toolPlanValue(allocator, context, planRequest(context, args)) catch |err| return planError(allocator, "zig_tool_plan", args, err);
    return structured(allocator, value);
}

fn structured(allocator: std.mem.Allocator, value: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_result.structured(allocator, value);
}

fn jsonTextOnly(allocator: std.mem.Allocator, bytes: []u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    errdefer allocator.free(bytes);
    const content = allocator.alloc(mcp.types.ContentBlock, 1) catch return error.OutOfMemory;
    content[0] = .{ .text = .{ .text = bytes } };
    return .{ .content = content };
}

fn planRequest(context: app_context.Context, args: ?std.json.Value) discovery.PlanRequest {
    return .{
        .tool = argString(args, "tool"),
        .file = argString(args, "file"),
        .path = argString(args, "path"),
        .args = argString(args, "args") orelse "",
        .timeout_ms = @max(1, @min(argInt(args, "timeout_ms", context.timeouts.command_ms), 60 * 60 * 1000)),
    };
}

fn planError(allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.MissingTool => mcp_errors.missingArgument(allocator, tool_name, "tool", "registered tool name"),
        error.UnknownTool => mcp_errors.invalidArgument(allocator, tool_name, "tool", "registered tool name", argString(args, "tool") orelse "", "Call zigar_capabilities or zigar_schema to inspect the registered tool names, then retry with one of those names."),
        error.MissingFile => missingPlanningArgument(allocator, tool_name, "file"),
        error.MissingPath => missingPlanningArgument(allocator, tool_name, "path"),
        error.InvalidExtraArgs => mcp_errors.invalidArgument(allocator, tool_name, "args", "shell-style argument string", argString(args, "args") orelse "", "Quote arguments the same way you would in a shell command, or omit the field when no extra arguments are needed."),
        error.PathOutsideWorkspace, error.EmptyPath => mcp_errors.workspacePath(allocator, tool_name, argString(args, "file") orelse argString(args, "path") orelse "", "", err),
        error.MissingPort => portToolError(allocator, tool_name, "build_app_context", err),
        else => portToolError(allocator, tool_name, "plan_tool", err),
    };
}

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

fn portToolError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "discovery_usecase",
        .code = "discovery_failed",
        .category = "discovery",
        .resolution = "Retry after confirming workspace, configured backend paths, and runtime ports with zigar_doctor.",
    }, err);
}

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
