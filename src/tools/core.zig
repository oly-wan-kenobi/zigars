const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const command = zigar.command;
const common = @import("common.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const workspacePathErrorResult = common.workspacePathErrorResult;
const runAndFormat = common.runAndFormat;
const runAndFormatTimeout = common.runAndFormatTimeout;
const toolTimeout = common.toolTimeout;
const commandResultValue = common.commandResultValue;
const backendErrorResult = common.backendErrorResult;
const splitToolArgs = common.splitToolArgs;
const compilerInsightsValue = common.compilerInsightsValue;
const ownedString = common.ownedString;
const buildExplainCommand = common.buildExplainCommand;
const explainCommandSetupError = common.explainCommandSetupError;
const freeArgList = common.freeArgList;

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
    return runAndFormat(a, allocator, &.{ a.config.zig_path, "env" }, "zig env");
}

pub fn zigTargets(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runAndFormat(a, allocator, &.{ a.config.zig_path, "targets" }, "zig targets");
}

pub fn zigBuild(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    const argv = command.joinArgv(allocator, &.{ a.config.zig_path, "build" }, extra) catch return error.OutOfMemory;
    defer allocator.free(argv);
    return runAndFormatTimeout(a, allocator, argv, "zig build", toolTimeout(a, args));
}

pub fn zigTest(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var resolved_file: ?[]const u8 = null;
    defer if (resolved_file) |path| allocator.free(path);
    list.append(allocator, a.config.zig_path) catch return error.OutOfMemory;
    if (argString(args, "file")) |file| {
        resolved_file = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_test", file, err);
        list.append(allocator, "test") catch return error.OutOfMemory;
        list.append(allocator, resolved_file.?) catch return error.OutOfMemory;
        if (argString(args, "filter")) |filter| {
            list.append(allocator, "--test-filter") catch return error.OutOfMemory;
            list.append(allocator, filter) catch return error.OutOfMemory;
        }
    } else {
        list.append(allocator, "build") catch return error.OutOfMemory;
        list.append(allocator, "test") catch return error.OutOfMemory;
    }
    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    list.appendSlice(allocator, extra) catch return error.OutOfMemory;
    return runAndFormatTimeout(a, allocator, list.items, "zig test", toolTimeout(a, args));
}

pub fn zigCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_check", file, err);
    defer allocator.free(resolved);
    return runAndFormatTimeout(a, allocator, &.{ a.config.zig_path, "ast-check", resolved }, "zig ast-check", toolTimeout(a, args));
}

pub fn zigCompileErrorIndex(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (argString(args, "text")) |raw_text| {
        const value = compilerErrorIndexValue(allocator, raw_text, "", &.{a.config.zig_path}) catch return error.OutOfMemory;
        return structured(allocator, value);
    }
    var list = buildExplainCommand(allocator, args, a) catch |err| return explainCommandSetupError(a, allocator, "zig_compile_error_index", args, err);
    defer {
        for (list.owned_paths.items) |path| allocator.free(path);
        list.owned_paths.deinit(allocator);
        list.argv.deinit(allocator);
    }
    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, list.argv.items, toolTimeout(a, args)) catch |err| {
        a.tool_errors += 1;
        return backendErrorResult(allocator, "zig", "compile_error_index", err, "confirm --zig-path is executable or pass captured compiler output as text");
    };
    defer result.deinit(allocator);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = result.succeeded() });
    try obj.put(allocator, "command", try commandResultValue(allocator, "zig compile error index", list.argv.items, a.workspace.root, toolTimeout(a, args), result));
    try obj.put(allocator, "index", try compilerErrorIndexValue(allocator, result.stderr, result.stdout, list.argv.items));
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
    var list = buildExplainCommand(allocator, args, a) catch |err| return explainCommandSetupError(a, allocator, "zig_explain_errors", args, err);
    defer {
        for (list.owned_paths.items) |path| allocator.free(path);
        list.owned_paths.deinit(allocator);
        list.argv.deinit(allocator);
    }

    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, list.argv.items, toolTimeout(a, args)) catch |err| {
        a.tool_errors += 1;
        return backendErrorResult(allocator, "zig", "explain_errors", err, "confirm --zig-path is executable or narrow the command arguments");
    };
    defer result.deinit(allocator);

    const command_value = commandResultValue(allocator, "zig explain errors", list.argv.items, a.workspace.root, toolTimeout(a, args), result) catch return error.OutOfMemory;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "mode", .{ .string = list.mode }) catch return error.OutOfMemory;
    obj.put(allocator, "ok", .{ .bool = result.succeeded() }) catch return error.OutOfMemory;
    if (command_value == .object) {
        if (command_value.object.get("diagnostics")) |diagnostics| {
            obj.put(allocator, "diagnostics", diagnostics) catch return error.OutOfMemory;
        }
    }
    obj.put(allocator, "command", command_value) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigTranslateC(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return error.InvalidArguments;
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_translate_c", file, err);
    defer allocator.free(resolved);
    const extra = try splitToolArgs(allocator, argString(args, "args"));
    defer freeArgList(allocator, extra);
    const base = &.{ a.config.zig_path, "translate-c", resolved };
    const argv = command.joinArgv(allocator, base, extra) catch return error.OutOfMemory;
    defer allocator.free(argv);
    return runAndFormatTimeout(a, allocator, argv, "zig translate-c", toolTimeout(a, args));
}
