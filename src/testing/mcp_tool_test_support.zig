//! Shared test harness for invoking MCP tools with minimal app bootstrap.

const std = @import("std");
const mcp = @import("mcp");
const zigars = @import("../root.zig");

const mcp_core = zigars.adapters.mcp.core;
const mcp_project_intelligence = zigars.adapters.mcp.project_intelligence;
const mcp_static_analysis = zigars.adapters.mcp.static_analysis;
const RuntimePorts = zigars.bootstrap.runtime_ports.RuntimePorts;
const workspace_mod = zigars.infra.workspace.workspace;

pub const App = zigars.bootstrap.runtime_state.App;

/// Creates a deterministic app fixture for command-planning tool tests.
pub fn appForCommandPlanning(allocator: std.mem.Allocator) !App {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .config = .{ .workspace = "/tmp", .zig_path = "zig" },
        .workspace = try workspace_mod.Workspace.init(allocator, std.testing.io, "/tmp", null),
    };
}

/// Manifest fixture for the zig_explain_errors tool.
pub fn zigExplainErrors(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{
        .non_exited_exit_code = 0,
        .record_command_observability = true,
    });
    const context = runtime_ports.coreContext() catch return error.OutOfMemory;
    return mcp_core.zigExplainErrors(allocator, context, args);
}

/// Manifest fixture for the zig_compile_error_index tool.
pub fn zigCompileErrorIndex(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{
        .non_exited_exit_code = 0,
        .record_command_observability = true,
    });
    const context = runtime_ports.coreContext() catch return error.OutOfMemory;
    return mcp_core.zigCompileErrorIndex(allocator, context, args);
}

/// Manifest fixture for the zigars_failure_fusion tool.
pub fn zigarsFailureFusion(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{ .workspace_read_resolution = .input });
    // This tool maps runtime setup faults into user-facing MCP tool errors.
    const context = runtime_ports.projectIntelligenceContext() catch |err| return mcp_project_intelligence.contextSetupError(allocator, "zigars_failure_fusion", err);
    return mcp_project_intelligence.zigarsFailureFusion(allocator, context, args);
}

/// Manifest fixture for the zig_target_matrix_plan tool.
pub fn zigTargetMatrixPlan(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{ .workspace_read_resolution = .input });
    const context = runtime_ports.context().staticAnalysis() catch return error.OutOfMemory;
    return mcp_static_analysis.zigTargetMatrixPlan(allocator, context, args);
}

/// Manifest fixture for the zig_public_api_diff tool.
pub fn zigPublicApiDiff(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{ .workspace_read_resolution = .input });
    const context = runtime_ports.context().staticAnalysis() catch return error.OutOfMemory;
    return mcp_static_analysis.zigPublicApiDiff(allocator, context, args);
}
