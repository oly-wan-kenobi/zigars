//! Performance MCP adapters for benchmark, coverage, and regression workflows.
const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const workflows = @import("../../../app/usecases/performance/workflows.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

/// Handles MCP `zig_coverage_run` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCoverageRun(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_coverage_run", workflows.zigCoverageRun);
}

/// Handles MCP `zig_coverage_map` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCoverageMap(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_coverage_map", workflows.zigCoverageMap);
}

/// Handles MCP `zig_coverage_merge` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCoverageMerge(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_coverage_merge", workflows.zigCoverageMerge);
}

/// Handles MCP `zig_coverage_diff` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCoverageDiff(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_coverage_diff", workflows.zigCoverageDiff);
}

/// Handles MCP `zig_coverage_baseline` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCoverageBaseline(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_coverage_baseline", workflows.zigCoverageBaseline);
}

/// Handles MCP `zig_coverage_budget_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCoverageBudgetCheck(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_coverage_budget_check", workflows.zigCoverageBudgetCheck);
}

/// Handles MCP `zig_bench_discover` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBenchDiscover(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_bench_discover", workflows.zigBenchDiscover);
}

/// Handles MCP `zig_bench_run` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBenchRun(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_bench_run", workflows.zigBenchRun);
}

/// Handles MCP `zig_bench_baseline` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBenchBaseline(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_bench_baseline", workflows.zigBenchBaseline);
}

/// Handles MCP `zig_benchmark_history` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBenchmarkHistory(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_benchmark_history", workflows.zigBenchmarkHistory);
}

/// Handles MCP `zig_bench_compare` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBenchCompare(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_bench_compare", workflows.zigBenchCompare);
}

/// Handles MCP `zig_bench_regression_gate` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBenchRegressionGate(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_bench_regression_gate", workflows.zigBenchRegressionGate);
}

/// Handles MCP `zig_perf_budget_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigPerfBudgetCheck(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_perf_budget_check", workflows.zigPerfBudgetCheck);
}

/// Handles MCP `zig_profile_regression` requests by delegating to app logic and shaping owned results/errors.
pub fn zigProfileRegression(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_profile_regression", workflows.zigProfileRegression);
}

/// Handles MCP `zig_samply_record` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSamplyRecord(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_samply_record", workflows.zigSamplyRecord);
}

/// Handles MCP `zig_samply_summary` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSamplySummary(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_samply_summary", workflows.zigSamplySummary);
}

/// Handles MCP `zig_samply_import` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSamplyImport(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_samply_import", workflows.zigSamplyImport);
}

/// Handles MCP `zig_samply_artifact` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSamplyArtifact(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_samply_artifact", workflows.zigSamplyArtifact);
}

/// Handles MCP `zig_profile_open` requests by delegating to app logic and shaping owned results/errors.
pub fn zigProfileOpen(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_profile_open", workflows.zigProfileOpen);
}

/// Handles MCP `zig_tracy_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTracyPlan(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_tracy_plan", workflows.zigTracyPlan);
}

/// Handles MCP `zig_tracy_probe` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTracyProbe(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_tracy_probe", workflows.zigTracyProbe);
}

/// Handles MCP `zig_tracy_capture` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTracyCapture(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_tracy_capture", workflows.zigTracyCapture);
}

/// Handles MCP `zig_tracy_artifacts` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTracyArtifacts(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_tracy_artifacts", workflows.zigTracyArtifacts);
}

/// Handles MCP `zig_tracy_hints` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTracyHints(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_tracy_hints", workflows.zigTracyHints);
}

/// Handles MCP `zig_perf_evidence_pack` requests by delegating to app logic and shaping owned results/errors.
pub fn zigPerfEvidencePack(allocator: std.mem.Allocator, context: app_context.PerformanceContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_perf_evidence_pack", workflows.zigPerfEvidencePack);
}

/// Invokes a use case and converts its result or failure into MCP output.
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

/// Maps usecase error failures to structured MCP errors.
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

const fakes = @import("../../../testing/fakes/root.zig");

test "performance adapter maps structured and thrown usecase failures" {
    const Stub = struct {
        /// Test stub that returns a structured tool failure.
        fn structuredFailure(_: *workflows.App, allocator: std.mem.Allocator, _: ?std.json.Value) !workflows.Result {
            var obj = std.json.ObjectMap.empty;
            const key = try allocator.dupe(u8, "kind");
            var key_owned = true;
            defer if (key_owned) allocator.free(key);
            const value = try allocator.dupe(u8, "performance_failure");
            var value_owned = true;
            defer if (value_owned) allocator.free(value);
            try obj.put(allocator, key, .{ .string = value });
            key_owned = false;
            value_owned = false;
            return .{ .value = .{ .object = obj }, .is_error = true };
        }

        /// Test stub that throws a tool failure error.
        fn thrownFailure(_: *workflows.App, _: std.mem.Allocator, _: ?std.json.Value) !workflows.Result {
            return error.AccessDenied;
        }

        /// Test stub that simulates allocation failure.
        fn oomFailure(_: *workflows.App, _: std.mem.Allocator, _: ?std.json.Value) !workflows.Result {
            return error.OutOfMemory;
        }
    };

    var runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer runner.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    const context: app_context.PerformanceContext = .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .tool_paths = .{},
        .timeouts = .{},
        .command_runner = runner.port(),
        .workspace_store = workspace.port(),
        .workspace_scanner = scanner.port(),
    };

    const structured = try invoke(std.testing.allocator, context, null, "zig_coverage_run", Stub.structuredFailure);
    defer mcp_result.deinitToolResult(std.testing.allocator, structured);
    try std.testing.expect(structured.is_error);
    try std.testing.expectEqualStrings("performance_failure", structured.structuredContent.?.object.get("kind").?.string);

    const thrown = try invoke(std.testing.allocator, context, null, "zig_coverage_run", Stub.thrownFailure);
    defer mcp_result.deinitToolResult(std.testing.allocator, thrown);
    try std.testing.expect(thrown.is_error);
    try std.testing.expectEqualStrings("tool_error", thrown.structuredContent.?.object.get("kind").?.string);

    try std.testing.expectError(error.OutOfMemory, invoke(std.testing.allocator, context, null, "zig_coverage_run", Stub.oomFailure));
}
