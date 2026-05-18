const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const command = zigar.command;
const common = @import("common.zig");

const App = common.App;
const structured = common.structured;
const argString = common.argString;
const missingArgumentResult = common.missingArgumentResult;
const workspacePathErrorResult = common.workspacePathErrorResult;
const toolTimeout = common.toolTimeout;
const commandResultValue = common.commandResultValue;
const commandRunErrorResult = common.commandRunErrorResult;
const splitToolArgs = common.splitToolArgs;
const splitToolArgsErrorResult = common.splitToolArgsErrorResult;
const freeArgList = common.freeArgList;

pub fn zigCiAnnotations(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_ci_annotations", "file", "workspace-relative Zig source path");
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_ci_annotations", file, err);
    defer allocator.free(resolved);
    a.command_calls += 1;
    const timeout_ms = toolTimeout(a, args);
    const argv = &.{ a.config.zig_path, "ast-check", resolved };
    const result = command.run(allocator, a.io, a.workspace.root, argv, timeout_ms) catch |err| return commandRunErrorResult(allocator, .{
        .tool = "zig_ci_annotations",
        .operation = "run_ast_check",
        .phase = "execute_backend",
        .code = "ast_check_command_failed",
        .backend = "zig",
        .argv = argv,
        .cwd = a.workspace.root,
        .timeout_ms = timeout_ms,
        .err = err,
        .resolution = "Confirm --zig-path points to an executable Zig binary and retry with a readable workspace file.",
    });
    defer result.deinit(allocator);
    var annotations = std.json.Array.init(allocator);
    tryParseAnnotations(allocator, &annotations, file, result.stderr) catch return error.OutOfMemory;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "ok", .{ .bool = result.succeeded() }) catch return error.OutOfMemory;
    obj.put(allocator, "annotations", .{ .array = annotations }) catch return error.OutOfMemory;
    obj.put(allocator, "raw", commandResultValue(allocator, "zig ast-check", argv, a.workspace.root, timeout_ms, result) catch return error.OutOfMemory) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn tryParseAnnotations(allocator: std.mem.Allocator, annotations: *std.json.Array, default_file: []const u8, stderr: []const u8) !void {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var file = default_file;
        var line_no: i64 = 1;
        var col_no: i64 = 1;
        if (std.mem.indexOf(u8, line, ".zig:")) |zig_pos| {
            const prefix_end = zig_pos + ".zig".len;
            file = line[0..prefix_end];
            var rest = line[prefix_end..];
            if (std.mem.startsWith(u8, rest, ":")) rest = rest[1..];
            if (std.mem.indexOfScalar(u8, rest, ':')) |line_end| {
                line_no = std.fmt.parseInt(i64, rest[0..line_end], 10) catch 1;
                const after_line = rest[line_end + 1 ..];
                if (std.mem.indexOfScalar(u8, after_line, ':')) |col_end| {
                    col_no = std.fmt.parseInt(i64, after_line[0..col_end], 10) catch 1;
                }
            }
        }
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "path", .{ .string = file });
        try obj.put(allocator, "start_line", .{ .integer = line_no });
        try obj.put(allocator, "start_column", .{ .integer = col_no });
        try obj.put(allocator, "annotation_level", .{ .string = "failure" });
        try obj.put(allocator, "message", .{ .string = line });
        try annotations.append(.{ .object = obj });
    }
}

pub fn xmlEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn zigJunit(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(allocator);
    var resolved_file: ?[]const u8 = null;
    defer if (resolved_file) |path| allocator.free(path);
    list.append(allocator, a.config.zig_path) catch return error.OutOfMemory;
    if (argString(args, "file")) |file| {
        resolved_file = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_junit", file, err);
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
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, "zig_junit", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    list.appendSlice(allocator, extra) catch return error.OutOfMemory;
    a.command_calls += 1;
    const timeout_ms = toolTimeout(a, args);
    const result = command.run(allocator, a.io, a.workspace.root, list.items, timeout_ms) catch |err| return commandRunErrorResult(allocator, .{
        .tool = "zig_junit",
        .operation = "run_tests",
        .phase = "execute_backend",
        .code = "test_command_failed",
        .backend = "zig",
        .argv = list.items,
        .cwd = a.workspace.root,
        .timeout_ms = timeout_ms,
        .err = err,
        .resolution = "Confirm --zig-path points to an executable Zig binary and retry with a valid test target.",
    });
    defer result.deinit(allocator);
    const stdout_xml = xmlEscape(allocator, result.stdout) catch return error.OutOfMemory;
    defer allocator.free(stdout_xml);
    const stderr_xml = xmlEscape(allocator, result.stderr) catch return error.OutOfMemory;
    defer allocator.free(stderr_xml);
    const failure_xml = if (result.succeeded())
        allocator.dupe(u8, "") catch return error.OutOfMemory
    else
        allocator.dupe(u8, "<failure message=\"zig test failed\"/>") catch return error.OutOfMemory;
    defer allocator.free(failure_xml);
    const xml = std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<testsuite name="zigar" tests="1" failures="{d}">
        \\  <testcase classname="zig" name="zig test">
        \\    {s}
        \\  </testcase>
        \\  <system-out>{s}</system-out>
        \\  <system-err>{s}</system-err>
        \\</testsuite>
        \\
    , .{ if (result.succeeded()) @as(i32, 0) else @as(i32, 1), failure_xml, stdout_xml, stderr_xml }) catch return error.OutOfMemory;
    defer allocator.free(xml);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "ok", .{ .bool = result.succeeded() }) catch return error.OutOfMemory;
    obj.put(allocator, "junit_xml", .{ .string = xml }) catch return error.OutOfMemory;
    obj.put(allocator, "command", commandResultValue(allocator, "zig test", list.items, a.workspace.root, timeout_ms, result) catch return error.OutOfMemory) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn zigMatrixCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const paths_text = argString(args, "zig_paths") orelse a.config.zig_path;
    var paths = std.mem.tokenizeAny(u8, paths_text, ", \t\r\n");
    var results = std.json.Array.init(allocator);
    while (paths.next()) |zig_path| {
        const raw_extra_args = argString(args, "args") orelse "";
        const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, "zig_matrix_check", "args", raw_extra_args, err);
        defer freeArgList(allocator, extra);
        const argv = command.joinArgv(allocator, &.{ zig_path, "build", "test" }, extra) catch return error.OutOfMemory;
        defer allocator.free(argv);
        a.command_calls += 1;
        const run = command.run(allocator, a.io, a.workspace.root, argv, toolTimeout(a, args)) catch |err| {
            var err_obj = std.json.ObjectMap.empty;
            err_obj.put(allocator, "zig", .{ .string = zig_path }) catch return error.OutOfMemory;
            err_obj.put(allocator, "ok", .{ .bool = false }) catch return error.OutOfMemory;
            err_obj.put(allocator, "error", .{ .string = @errorName(err) }) catch return error.OutOfMemory;
            results.append(.{ .object = err_obj }) catch return error.OutOfMemory;
            continue;
        };
        defer run.deinit(allocator);
        var item = std.json.ObjectMap.empty;
        item.put(allocator, "zig", .{ .string = zig_path }) catch return error.OutOfMemory;
        item.put(allocator, "result", commandResultValue(allocator, "zig build test", argv, a.workspace.root, toolTimeout(a, args), run) catch return error.OutOfMemory) catch return error.OutOfMemory;
        results.append(.{ .object = item }) catch return error.OutOfMemory;
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "results", .{ .array = results }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}
