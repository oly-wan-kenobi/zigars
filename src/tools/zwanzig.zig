const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const command = zigar.command;
const common = @import("common.zig");

const App = common.App;
const argString = common.argString;
const missingArgumentResult = common.missingArgumentResult;
const workspacePathErrorResult = common.workspacePathErrorResult;
const runAndFormat = common.runAndFormat;
const splitToolArgs = common.splitToolArgs;
const splitToolArgsErrorResult = common.splitToolArgsErrorResult;
const freeArgList = common.freeArgList;

pub fn zigLint(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runZwanzig(a, allocator, args, "json");
}

pub fn zigLintSarif(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runZwanzig(a, allocator, args, "sarif");
}

pub fn runZwanzig(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, format: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var resolved_config: ?[]const u8 = null;
    defer if (resolved_config) |path| allocator.free(path);
    list.append(allocator, a.config.zwanzig_path) catch return error.OutOfMemory;
    list.append(allocator, "--format") catch return error.OutOfMemory;
    list.append(allocator, format) catch return error.OutOfMemory;
    if (argString(args, "config")) |path| {
        resolved_config = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_lint", path, err);
        list.append(allocator, "--config") catch return error.OutOfMemory;
        list.append(allocator, resolved_config.?) catch return error.OutOfMemory;
    }
    if (argString(args, "rules_do")) |rules| {
        list.append(allocator, "--do") catch return error.OutOfMemory;
        list.append(allocator, rules) catch return error.OutOfMemory;
    }
    if (argString(args, "rules_skip")) |rules| {
        list.append(allocator, "--skip") catch return error.OutOfMemory;
        list.append(allocator, rules) catch return error.OutOfMemory;
    }
    const path = argString(args, "path") orelse ".";
    const resolved_path = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_lint", path, err);
    defer allocator.free(resolved_path);
    list.append(allocator, resolved_path) catch return error.OutOfMemory;
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, "zig_lint", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    list.appendSlice(allocator, extra) catch return error.OutOfMemory;
    return runAndFormat(a, allocator, list.items, "zwanzig");
}

pub fn zigLintRules(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runAndFormat(a, allocator, &.{ a.config.zwanzig_path, "--help" }, "zwanzig rules/help");
}

pub fn zigAnalysisGraphs(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const path = argString(args, "path") orelse return missingArgumentResult(allocator, "zig_analysis_graphs", "path", "workspace-relative Zig source path");
    const output = argString(args, "output") orelse return missingArgumentResult(allocator, "zig_analysis_graphs", "output", "workspace-relative DOT output path");
    const resolved_path = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_analysis_graphs", path, err);
    defer allocator.free(resolved_path);
    const resolved_output = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_analysis_graphs", output, err);
    defer allocator.free(resolved_output);
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, "zig_analysis_graphs", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    const base = &.{ a.config.zwanzig_path, "--dot", resolved_output, resolved_path };
    const argv = command.joinArgv(allocator, base, extra) catch return error.OutOfMemory;
    defer allocator.free(argv);
    return runAndFormat(a, allocator, argv, "zwanzig graph");
}
