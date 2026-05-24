const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("../root.zig");

const mcp_core = zigar.adapters.mcp.core;
const mcp_project_intelligence = zigar.adapters.mcp.project_intelligence;
const mcp_static_analysis = zigar.adapters.mcp.static_analysis;
const RuntimePorts = zigar.bootstrap.runtime_ports.RuntimePorts;
const workspace_mod = zigar.infra.workspace.workspace;

pub const App = zigar.bootstrap.runtime_state.App;

pub fn appForCommandPlanning(allocator: std.mem.Allocator) !App {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .config = .{ .workspace = "/tmp", .zig_path = "zig" },
        .workspace = try workspace_mod.Workspace.init(allocator, std.testing.io, "/tmp", null),
    };
}

pub fn zigExplainErrors(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{
        .non_exited_exit_code = 0,
        .record_command_observability = true,
    });
    const context = runtime_ports.coreContext() catch return error.OutOfMemory;
    return mcp_core.zigExplainErrors(allocator, context, args);
}

pub fn zigCompileErrorIndex(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{
        .non_exited_exit_code = 0,
        .record_command_observability = true,
    });
    const context = runtime_ports.coreContext() catch return error.OutOfMemory;
    return mcp_core.zigCompileErrorIndex(allocator, context, args);
}

pub fn zigarFailureFusion(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{ .workspace_read_resolution = .input });
    const context = runtime_ports.projectIntelligenceContext() catch |err| return mcp_project_intelligence.contextSetupError(allocator, "zigar_failure_fusion", err);
    return mcp_project_intelligence.zigarFailureFusion(allocator, context, args);
}

pub fn zigTargetMatrixPlan(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{ .workspace_read_resolution = .input });
    const context = runtime_ports.context().staticAnalysis() catch return error.OutOfMemory;
    return mcp_static_analysis.zigTargetMatrixPlan(allocator, context, args);
}

pub fn zigPublicApiDiff(app: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = RuntimePorts.init(app, .{ .workspace_read_resolution = .input });
    const context = runtime_ports.context().staticAnalysis() catch return error.OutOfMemory;
    return mcp_static_analysis.zigPublicApiDiff(allocator, context, args);
}
