const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const workflows = @import("../../../app/usecases/release/workflows.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

pub fn zigDependencyUpdatePlan(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_update_plan", workflows.zigDependencyUpdatePlan);
}

pub fn zigDependencyFetchCheck(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_fetch_check", workflows.zigDependencyFetchCheck);
}

pub fn zigDependencyLockAudit(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_lock_audit", workflows.zigDependencyLockAudit);
}

pub fn zigDependencyImpact(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_impact", workflows.zigDependencyImpact);
}

pub fn zigSbom(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_sbom", workflows.zigSbom);
}

pub fn zigZatScan(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_zat_scan", workflows.zigZatScan);
}

pub fn zigOsvScan(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_osv_scan", workflows.zigOsvScan);
}

pub fn zigDependencySecurityReport(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_security_report", workflows.zigDependencySecurityReport);
}

pub fn zigDependencyProvenance(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_provenance", workflows.zigDependencyProvenance);
}

pub fn zigDependencyLicenseSummary(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dependency_license_summary", workflows.zigDependencyLicenseSummary);
}

pub fn zigGithubDependencySubmitPlan(allocator: std.mem.Allocator, context: app_context.ReleaseWorkflowContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_github_dependency_submit_plan", workflows.zigGithubDependencySubmitPlan);
}

fn invoke(
    allocator: std.mem.Allocator,
    context: app_context.ReleaseWorkflowContext,
    args: ?std.json.Value,
    comptime tool_name: []const u8,
    comptime func: anytype,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var app = workflows.App.init(context, allocator);
    const result = func(&app, allocator, args) catch |err| return usecaseError(allocator, tool_name, err);
    if (result.is_error) {
        defer mcp_result.deinitOwnedValue(allocator, result.value);
        return mcp_result.structuredError(allocator, result.value);
    }
    return mcp_result.structuredOwned(allocator, result.value);
}

fn usecaseError(allocator: std.mem.Allocator, tool_name: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = "dependency_workflow",
        .phase = "run_usecase",
        .code = "dependency_usecase_failed",
        .category = "dependencies",
        .resolution = "Retry after confirming manifest paths, supplied scanner evidence, and workspace inputs.",
    }, err);
}
