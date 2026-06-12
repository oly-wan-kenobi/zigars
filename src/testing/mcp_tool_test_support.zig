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

/// Returns an App wired to the test process cwd with a synthetic zig path
/// suitable for command-planning tool fixtures that do not invoke real Zig
/// builds or touch workspace files. The cwd always exists on every platform
/// ("/tmp" does not exist on Windows). Caller owns the returned App and must
/// call deinit when done.
pub fn appForCommandPlanning(allocator: std.mem.Allocator) !App {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .config = .{ .workspace = ".", .zig_path = "zig" },
        .workspace = try workspace_mod.Workspace.init(allocator, std.testing.io, ".", null),
    };
}

/// Invokes zig_explain_errors through a real RuntimePorts context wired to app.
/// non_exited_exit_code=0 ensures the fake command runner reports success for
/// any subprocess the tool triggers.
pub fn zigExplainErrors(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{
        .non_exited_exit_code = 0,
        .record_command_observability = true,
    });
    const context = runtime_ports.coreContext() catch return error.OutOfMemory;
    return mcp_core.zigExplainErrors(allocator, context, args);
}

/// Invokes zig_compile_error_index through a real RuntimePorts context wired to app.
pub fn zigCompileErrorIndex(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{
        .non_exited_exit_code = 0,
        .record_command_observability = true,
    });
    const context = runtime_ports.coreContext() catch return error.OutOfMemory;
    return mcp_core.zigCompileErrorIndex(allocator, context, args);
}

/// Invokes zigars_failure_fusion through a real RuntimePorts context wired to app.
/// Context setup faults are mapped to structured tool errors rather than propagated,
/// matching the handler's own error surfacing contract.
pub fn zigarsFailureFusion(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{ .workspace_read_resolution = .input });
    // This tool maps runtime setup faults into user-facing MCP tool errors.
    const context = runtime_ports.projectIntelligenceContext() catch |err| return mcp_project_intelligence.contextSetupError(allocator, "zigars_failure_fusion", err);
    return mcp_project_intelligence.zigarsFailureFusion(allocator, context, args);
}

/// Invokes zig_target_matrix_plan through a static-analysis context wired to app.
/// workspace_read_resolution=.input enforces sandbox path resolution on the args.
pub fn zigTargetMatrixPlan(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{ .workspace_read_resolution = .input });
    const context = runtime_ports.context().staticAnalysis() catch return error.OutOfMemory;
    return mcp_static_analysis.zigTargetMatrixPlan(allocator, context, args);
}

/// Invokes zig_public_api_diff through a static-analysis context wired to app.
pub fn zigPublicApiDiff(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{ .workspace_read_resolution = .input });
    const context = runtime_ports.context().staticAnalysis() catch return error.OutOfMemory;
    return mcp_static_analysis.zigPublicApiDiff(allocator, context, args);
}
