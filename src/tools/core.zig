const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const command = zigar.command;
const bootstrap_runtime_ports = zigar.bootstrap.runtime_ports;
const core_usecase = zigar.app.usecases.core.zig_commands;
const common = @import("common.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const missingArgumentResult = common.missingArgumentResult;
const workspacePathErrorResult = common.workspacePathErrorResult;
const toolTimeout = common.toolTimeout;
const portCommandResultValue = common.portCommandResultValue;
const portCommandErrorValue = common.portCommandErrorValue;
const backendErrorResult = common.backendErrorResult;
const splitToolArgs = common.splitToolArgs;
const splitToolArgsErrorResult = common.splitToolArgsErrorResult;
const compilerInsightsValue = common.compilerInsightsValue;
const ownedString = common.ownedString;
const freeArgList = common.freeArgList;

const core_command_ports_options = bootstrap_runtime_ports.Options{
    .non_exited_exit_code = 0,
    .record_command_observability = true,
};

pub fn zigVersion(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const zig = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zig_path, "version" }, a.config.timeout_ms) catch |err| {
        return backendErrorResult(allocator, "zig", "version", err, "confirm --zig-path points to an executable Zig 0.16.0 binary");
    };
    defer zig.deinit(allocator);
    const zls = command.run(allocator, a.io, a.workspace.root, &.{ a.config.zls_path, "--version" }, a.config.timeout_ms) catch null;
    defer if (zls) |r| r.deinit(allocator);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "zig", .{ .string = std.mem.trim(u8, zig.stdout, " \t\r\n") }) catch return error.OutOfMemory;
    obj.put(allocator, "zig_ok", .{ .bool = zig.succeeded() }) catch return error.OutOfMemory;
    if (zls) |r| {
        obj.put(allocator, "zls", .{ .string = std.mem.trim(u8, r.stdout, " \t\r\n") }) catch return error.OutOfMemory;
        obj.put(allocator, "zls_ok", .{ .bool = r.succeeded() }) catch return error.OutOfMemory;
    } else {
        obj.put(allocator, "zls", .{ .string = "unavailable" }) catch return error.OutOfMemory;
        obj.put(allocator, "zls_ok", .{ .bool = false }) catch return error.OutOfMemory;
    }
    obj.put(allocator, "zls_status", .{ .string = a.zls_status }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigEnv(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = bootstrap_runtime_ports.RuntimePorts.init(a, core_command_ports_options);
    const ctx = runtime_ports.coreContext() catch return error.OutOfMemory;
    var outcome = core_usecase.env(allocator, ctx, .{}) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return commandOutcomeResult(a, allocator, "zig_env", outcome);
}

pub fn zigTargets(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var runtime_ports = bootstrap_runtime_ports.RuntimePorts.init(a, core_command_ports_options);
    const ctx = runtime_ports.coreContext() catch return error.OutOfMemory;
    var outcome = core_usecase.targets(allocator, ctx, .{}) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return commandOutcomeResult(a, allocator, "zig_targets", outcome);
}

pub fn zigBuild(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, "zig_build", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    var runtime_ports = bootstrap_runtime_ports.RuntimePorts.init(a, core_command_ports_options);
    const ctx = runtime_ports.coreContext() catch return error.OutOfMemory;
    var outcome = core_usecase.build(allocator, ctx, .{
        .extra_args = extra,
        .timeout_ms = toolTimeout(a, args),
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return commandOutcomeResult(a, allocator, "zig_build", outcome);
}

pub fn zigTest(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, "zig_test", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    var runtime_ports = bootstrap_runtime_ports.RuntimePorts.init(a, core_command_ports_options);
    const ctx = runtime_ports.coreContext() catch return error.OutOfMemory;
    var outcome = core_usecase.testCommand(allocator, ctx, .{
        .file = argString(args, "file"),
        .filter = argString(args, "filter"),
        .extra_args = extra,
        .timeout_ms = toolTimeout(a, args),
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return commandOutcomeResult(a, allocator, "zig_test", outcome);
}

pub fn zigCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_check", "file", "workspace-relative Zig source path");
    var runtime_ports = bootstrap_runtime_ports.RuntimePorts.init(a, core_command_ports_options);
    const ctx = runtime_ports.coreContext() catch return error.OutOfMemory;
    var outcome = core_usecase.check(allocator, ctx, .{
        .file = file,
        .timeout_ms = toolTimeout(a, args),
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return commandOutcomeResult(a, allocator, "zig_check", outcome);
}

pub fn zigCompileErrorIndex(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (argString(args, "text")) |raw_text| {
        const value = compilerErrorIndexValue(allocator, raw_text, "", &.{a.config.zig_path}) catch return error.OutOfMemory;
        return structured(allocator, value);
    }
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, "zig_compile_error_index", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    var runtime_ports = bootstrap_runtime_ports.RuntimePorts.init(a, core_command_ports_options);
    const ctx = runtime_ports.coreContext() catch return error.OutOfMemory;
    var outcome = core_usecase.explainCommand(allocator, ctx, .{
        .command = argString(args, "command"),
        .file = argString(args, "file"),
        .extra_args = extra,
        .timeout_ms = toolTimeout(a, args),
    }, "zig compile error index") catch return error.OutOfMemory;
    defer outcome.deinit(allocator);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const run = switch (outcome) {
        .ok => |*value| &value.command,
        .err => |*failure| return explainFailureResult(a, allocator, "zig_compile_error_index", failure.*, "compile_error_index", "confirm --zig-path is executable or pass captured compiler output as text"),
    };
    try obj.put(allocator, "ok", .{ .bool = !run.result.effectiveTerm().failed() and !run.result.timed_out });
    try obj.put(allocator, "command", try portCommandResultValue(allocator, run.title, run.argv.items, run.cwd, run.timeout_ms, run.stdout_limit, run.stderr_limit, run.result));
    try obj.put(allocator, "index", try compilerErrorIndexValue(allocator, run.result.stderr, run.result.stdout, run.argv.items));
    return structured(allocator, .{ .object = obj });
}

pub fn compilerErrorIndexValue(allocator: std.mem.Allocator, stderr: []const u8, stdout: []const u8, argv: []const []const u8) !std.json.Value {
    const insights = try compilerInsightsValue(allocator, stdout, stderr, argv);
    const insights_obj = switch (insights) {
        .object => |o| o,
        else => return insights,
    };
    var files = std.json.Array.init(allocator);
    const findings = switch (insights_obj.get("findings") orelse .null) {
        .array => |a| a,
        else => std.json.Array.init(allocator),
    };
    for (findings.items) |finding| {
        const finding_obj = switch (finding) {
            .object => |o| o,
            else => continue,
        };
        const path = switch (finding_obj.get("path") orelse .null) {
            .string => |s| s,
            else => "(unlocated)",
        };
        var found_index: ?usize = null;
        for (files.items, 0..) |file_value, index| {
            const file_obj = switch (file_value) {
                .object => |o| o,
                else => continue,
            };
            const existing = switch (file_obj.get("path") orelse .null) {
                .string => |s| s,
                else => continue,
            };
            if (std.mem.eql(u8, existing, path)) {
                found_index = index;
                break;
            }
        }
        if (found_index) |index| {
            var file_obj = files.items[index].object;
            var file_findings = file_obj.get("findings").?.array;
            try file_findings.append(finding);
            try file_obj.put(allocator, "findings", .{ .array = file_findings });
            try file_obj.put(allocator, "count", .{ .integer = @intCast(file_findings.items.len) });
            files.items[index] = .{ .object = file_obj };
        } else {
            var file_findings = std.json.Array.init(allocator);
            try file_findings.append(finding);
            var file_obj = std.json.ObjectMap.empty;
            try file_obj.put(allocator, "path", try ownedString(allocator, path));
            try file_obj.put(allocator, "count", .{ .integer = 1 });
            try file_obj.put(allocator, "findings", .{ .array = file_findings });
            try files.append(.{ .object = file_obj });
        }
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_compile_error_index" });
    try obj.put(allocator, "summary", insights);
    try obj.put(allocator, "files", .{ .array = files });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(files.items.len) });
    return .{ .object = obj };
}

pub fn zigExplainErrors(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, "zig_explain_errors", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    var runtime_ports = bootstrap_runtime_ports.RuntimePorts.init(a, core_command_ports_options);
    const ctx = runtime_ports.coreContext() catch return error.OutOfMemory;
    var outcome = core_usecase.explainCommand(allocator, ctx, .{
        .command = argString(args, "command"),
        .file = argString(args, "file"),
        .extra_args = extra,
        .timeout_ms = toolTimeout(a, args),
    }, "zig explain errors") catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    const explain = switch (outcome) {
        .ok => |*value| value,
        .err => |*failure| return explainFailureResult(a, allocator, "zig_explain_errors", failure.*, "explain_errors", "confirm --zig-path is executable or narrow the command arguments"),
    };
    const run = &explain.command;

    const command_value = portCommandResultValue(allocator, run.title, run.argv.items, run.cwd, run.timeout_ms, run.stdout_limit, run.stderr_limit, run.result) catch return error.OutOfMemory;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "mode", .{ .string = explain.mode }) catch return error.OutOfMemory;
    obj.put(allocator, "ok", .{ .bool = !run.result.effectiveTerm().failed() and !run.result.timed_out }) catch return error.OutOfMemory;
    if (command_value == .object) {
        if (command_value.object.get("diagnostics")) |diagnostics| {
            obj.put(allocator, "diagnostics", diagnostics) catch return error.OutOfMemory;
        }
    }
    obj.put(allocator, "command", command_value) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigTranslateC(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_translate_c", "file", "workspace-relative C source path");
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, "zig_translate_c", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    var runtime_ports = bootstrap_runtime_ports.RuntimePorts.init(a, core_command_ports_options);
    const ctx = runtime_ports.coreContext() catch return error.OutOfMemory;
    var outcome = core_usecase.translateC(allocator, ctx, .{
        .file = file,
        .extra_args = extra,
        .timeout_ms = toolTimeout(a, args),
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return commandOutcomeResult(a, allocator, "zig_translate_c", outcome);
}

fn commandOutcomeResult(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, outcome: core_usecase.CommandOutcome) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (outcome) {
        .ok => |run| structured(
            allocator,
            portCommandResultValue(allocator, run.title, run.argv.items, run.cwd, run.timeout_ms, run.stdout_limit, run.stderr_limit, run.result) catch return error.OutOfMemory,
        ),
        .err => |failure| commandFailureResult(a, allocator, tool_name, failure),
    };
}

fn explainFailureResult(
    a: *App,
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    failure: core_usecase.Failure,
    operation: []const u8,
    resolution: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (failure) {
        .command_run => |command_failure| backendErrorResult(allocator, "zig", operation, command_failure.err, resolution),
        .workspace_path => |workspace_failure| workspacePathErrorResult(a, allocator, tool_name, workspace_failure.path, error.PathOutsideWorkspace),
        else => commandFailureResult(a, allocator, tool_name, failure),
    };
}

fn commandFailureResult(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, failure: core_usecase.Failure) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (failure) {
        .argument => |app_error| appArgumentErrorResult(allocator, tool_name, app_error),
        .workspace_path => |workspace_failure| workspacePathErrorResult(a, allocator, tool_name, workspace_failure.path, workspace_failure.err),
        .command_run => |command_failure| structured(
            allocator,
            portCommandErrorValue(allocator, command_failure.title, command_failure.argv.items, command_failure.cwd, command_failure.timeout_ms, command_failure.err) catch return error.OutOfMemory,
        ),
    };
}

fn appArgumentErrorResult(allocator: std.mem.Allocator, tool_name: []const u8, app_error: zigar.app.errors.AppError) mcp.tools.ToolError!mcp.tools.ToolResult {
    const field = app_error.field orelse "argument";
    const expected = app_error.expected orelse "valid argument";
    if (std.mem.eql(u8, app_error.code, "missing_required_argument")) {
        return missingArgumentResult(allocator, tool_name, field, expected);
    }
    return common.invalidArgumentResult(
        allocator,
        tool_name,
        field,
        expected,
        app_error.actual orelse "",
        app_error.resolution,
    );
}
