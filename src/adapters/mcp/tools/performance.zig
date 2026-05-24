const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const workflows = @import("../../../app/usecases/performance/workflows.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

pub fn zigCoverageRun(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_coverage_run", workflows.zigCoverageRun);
}

pub fn zigCoverageMap(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_coverage_map", workflows.zigCoverageMap);
}

pub fn zigCoverageMerge(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_coverage_merge", workflows.zigCoverageMerge);
}

pub fn zigCoverageDiff(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_coverage_diff", workflows.zigCoverageDiff);
}

pub fn zigCoverageBaseline(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_coverage_baseline", workflows.zigCoverageBaseline);
}

pub fn zigCoverageBudgetCheck(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_coverage_budget_check", workflows.zigCoverageBudgetCheck);
}

pub fn zigBenchDiscover(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_bench_discover", workflows.zigBenchDiscover);
}

pub fn zigBenchRun(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_bench_run", workflows.zigBenchRun);
}

pub fn zigBenchBaseline(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_bench_baseline", workflows.zigBenchBaseline);
}

pub fn zigBenchmarkHistory(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_benchmark_history", workflows.zigBenchmarkHistory);
}

pub fn zigBenchCompare(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_bench_compare", workflows.zigBenchCompare);
}

pub fn zigPerfBudgetCheck(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_perf_budget_check", workflows.zigPerfBudgetCheck);
}

pub fn zigProfileRegression(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_profile_regression", workflows.zigProfileRegression);
}

pub fn zigSamplyRecord(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_samply_record", workflows.zigSamplyRecord);
}

pub fn zigSamplySummary(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_samply_summary", workflows.zigSamplySummary);
}

pub fn zigSamplyImport(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_samply_import", workflows.zigSamplyImport);
}

pub fn zigSamplyArtifact(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_samply_artifact", workflows.zigSamplyArtifact);
}

pub fn zigProfileOpen(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_profile_open", workflows.zigProfileOpen);
}

pub fn zigTracyPlan(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_tracy_plan", workflows.zigTracyPlan);
}

pub fn zigTracyProbe(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_tracy_probe", workflows.zigTracyProbe);
}

pub fn zigTracyCapture(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_tracy_capture", workflows.zigTracyCapture);
}

pub fn zigTracyArtifacts(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_tracy_artifacts", workflows.zigTracyArtifacts);
}

pub fn zigTracyHints(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_tracy_hints", workflows.zigTracyHints);
}

pub fn zigPerfEvidencePack(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_perf_evidence_pack", workflows.zigPerfEvidencePack);
}

fn invoke(
    allocator: std.mem.Allocator,
    context: app_context.PerformanceContext,
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
        .operation = "performance_workflow",
        .phase = "run_usecase",
        .code = "performance_usecase_failed",
        .category = "performance",
        .resolution = "Retry after confirming the supplied evidence, workspace paths, and optional backend paths.",
    }, err);
}
