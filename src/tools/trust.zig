const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const common = @import("common.zig");

const App = common.App;
const argBool = common.argBool;
const argString = common.argString;
const invalidArgumentResult = common.invalidArgumentResult;
const structured = common.structured;
const toolTimeout = common.toolTimeout;

pub fn zigarTrustReport(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const include_clean_tree = argBool(args, "include_clean_tree", false);
    const value = zigar.trust.trustReport(allocator, a, include_clean_tree, toolTimeout(a, args)) catch return error.OutOfMemory;
    return structured(allocator, value);
}

pub fn zigarCommandProvenance(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const tool = argString(args, "tool");
    const value = zigar.trust.commandProvenance(allocator, tool) catch |err| switch (err) {
        error.UnknownTool => return invalidArgumentResult(allocator, "zigar_command_provenance", "tool", "registered zigar tool name", tool orelse "", "Call zigar_tool_index or zigar_schema to choose a registered tool name."),
        error.OutOfMemory => return error.OutOfMemory,
    };
    return structured(allocator, value);
}

pub fn zigarRiskAudit(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const include_none = argBool(args, "include_none", false);
    const value = zigar.trust.riskAudit(allocator, include_none) catch return error.OutOfMemory;
    return structured(allocator, value);
}

pub fn zigarCleanTreeGate(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const value = zigar.trust.cleanTreeGate(allocator, a, .{ .timeout_ms = toolTimeout(a, args) }) catch return error.OutOfMemory;
    return structured(allocator, value);
}
