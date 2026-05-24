const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const app_errors = @import("../../../app/errors.zig");
const ports = @import("../../../app/ports.zig");
const compiler_output = @import("../../../domain/zig/compiler_output.zig");
const core_usecase = @import("../../../app/usecases/core/zig_commands.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

const output_limit_mode = "truncate_on_limit";

pub fn zigVersion(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var outcome = core_usecase.version(allocator, context, .{
        .timeout_ms = toolTimeout(context, args),
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);

    return switch (outcome) {
        .ok => |*version_result| versionResult(allocator, version_result.*),
        .err => |failure| versionFailureResult(allocator, failure),
    };
}

pub fn zigEnv(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var outcome = core_usecase.env(allocator, context, .{}) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return commandOutcomeResult(allocator, context, "zig_env", outcome);
}

pub fn zigTargets(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var outcome = core_usecase.targets(allocator, context, .{}) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return commandOutcomeResult(allocator, context, "zig_targets", outcome);
}

pub fn zigBuild(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitArgs(allocator, raw_extra_args) catch |err| return splitToolArgsError(allocator, "zig_build", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    var outcome = core_usecase.build(allocator, context, .{
        .extra_args = extra,
        .timeout_ms = toolTimeout(context, args),
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return commandOutcomeResult(allocator, context, "zig_build", outcome);
}

pub fn zigTest(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitArgs(allocator, raw_extra_args) catch |err| return splitToolArgsError(allocator, "zig_test", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    var outcome = core_usecase.testCommand(allocator, context, .{
        .file = argString(args, "file"),
        .filter = argString(args, "filter"),
        .extra_args = extra,
        .timeout_ms = toolTimeout(context, args),
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return commandOutcomeResult(allocator, context, "zig_test", outcome);
}

pub fn zigCheck(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_check", "file", "workspace-relative Zig source path");
    var outcome = core_usecase.check(allocator, context, .{
        .file = file,
        .timeout_ms = toolTimeout(context, args),
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return commandOutcomeResult(allocator, context, "zig_check", outcome);
}

pub fn zigCompileErrorIndex(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (argString(args, "text")) |raw_text| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const value = compilerErrorIndexValue(arena.allocator(), raw_text, "", &.{context.tool_paths.zig}) catch return error.OutOfMemory;
        return mcp_result.structured(allocator, value);
    }
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitArgs(allocator, raw_extra_args) catch |err| return splitToolArgsError(allocator, "zig_compile_error_index", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    var outcome = core_usecase.explainCommand(allocator, context, .{
        .command = argString(args, "command"),
        .file = argString(args, "file"),
        .extra_args = extra,
        .timeout_ms = toolTimeout(context, args),
    }, "zig compile error index") catch return error.OutOfMemory;
    defer outcome.deinit(allocator);

    const explain = switch (outcome) {
        .ok => |*value| value,
        .err => |failure| return explainFailureResult(allocator, context, "zig_compile_error_index", failure, "compile_error_index", "confirm --zig-path is executable or pass captured compiler output as text"),
    };
    const run = &explain.command;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(scratch);
    try obj.put(scratch, "ok", .{ .bool = commandOk(run.result) });
    try obj.put(scratch, "command", try commandResultValue(scratch, run.*));
    try obj.put(scratch, "index", try compilerErrorIndexValue(scratch, run.result.stderr, run.result.stdout, run.argv.items));
    return mcp_result.structured(allocator, .{ .object = obj });
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

pub fn zigExplainErrors(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitArgs(allocator, raw_extra_args) catch |err| return splitToolArgsError(allocator, "zig_explain_errors", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    var outcome = core_usecase.explainCommand(allocator, context, .{
        .command = argString(args, "command"),
        .file = argString(args, "file"),
        .extra_args = extra,
        .timeout_ms = toolTimeout(context, args),
    }, "zig explain errors") catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    const explain = switch (outcome) {
        .ok => |*value| value,
        .err => |failure| return explainFailureResult(allocator, context, "zig_explain_errors", failure, "explain_errors", "confirm --zig-path is executable or narrow the command arguments"),
    };
    const run = &explain.command;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const command_value = commandResultValue(scratch, run.*) catch return error.OutOfMemory;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(scratch);
    try obj.put(scratch, "mode", .{ .string = explain.mode });
    try obj.put(scratch, "ok", .{ .bool = commandOk(run.result) });
    if (command_value == .object) {
        if (command_value.object.get("diagnostics")) |diagnostics| {
            try obj.put(scratch, "diagnostics", diagnostics);
        }
    }
    try obj.put(scratch, "command", command_value);
    return mcp_result.structured(allocator, .{ .object = obj });
}

pub fn zigTranslateC(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    args: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    const file = argString(args, "file") orelse return mcp_errors.missingArgument(allocator, "zig_translate_c", "file", "workspace-relative C source path");
    const raw_extra_args = argString(args, "args") orelse "";
    const extra = splitArgs(allocator, raw_extra_args) catch |err| return splitToolArgsError(allocator, "zig_translate_c", "args", raw_extra_args, err);
    defer freeArgList(allocator, extra);
    var outcome = core_usecase.translateC(allocator, context, .{
        .file = file,
        .extra_args = extra,
        .timeout_ms = toolTimeout(context, args),
    }) catch return error.OutOfMemory;
    defer outcome.deinit(allocator);
    return commandOutcomeResult(allocator, context, "zig_translate_c", outcome);
}

fn versionResult(allocator: std.mem.Allocator, result: core_usecase.VersionResult) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(scratch);
    try obj.put(scratch, "zig", .{ .string = std.mem.trim(u8, result.zig.result.stdout, " \t\r\n") });
    try obj.put(scratch, "zig_ok", .{ .bool = commandOk(result.zig.result) });
    if (result.zls) |zls_run| {
        try obj.put(scratch, "zls", .{ .string = std.mem.trim(u8, zls_run.result.stdout, " \t\r\n") });
        try obj.put(scratch, "zls_ok", .{ .bool = commandOk(zls_run.result) });
    } else {
        try obj.put(scratch, "zls", .{ .string = "unavailable" });
        try obj.put(scratch, "zls_ok", .{ .bool = false });
    }
    try obj.put(scratch, "zls_status", .{ .string = result.zls_status });
    return mcp_result.structured(allocator, .{ .object = obj });
}

fn versionFailureResult(allocator: std.mem.Allocator, failure: core_usecase.Failure) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (failure) {
        .command_run => |command_failure| backendErrorResult(allocator, "zig", "version", command_failure.err, "confirm --zig-path points to an executable Zig 0.16.0 binary"),
        .argument => |app_error| appArgumentErrorResult(allocator, "zig_version", app_error),
        .workspace_path => |workspace_failure| mcp_errors.workspacePath(allocator, "zig_version", workspace_failure.path, "", workspace_failure.err),
    };
}

fn commandOutcomeResult(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    tool_name: []const u8,
    outcome: core_usecase.CommandOutcome,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (outcome) {
        .ok => |run| blk: {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const value = commandResultValue(arena.allocator(), run) catch return error.OutOfMemory;
            break :blk mcp_result.structured(allocator, value);
        },
        .err => |failure| commandFailureResult(allocator, context, tool_name, failure),
    };
}

fn explainFailureResult(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    tool_name: []const u8,
    failure: core_usecase.Failure,
    operation: []const u8,
    resolution: []const u8,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (failure) {
        .command_run => |command_failure| backendErrorResult(allocator, "zig", operation, command_failure.err, resolution),
        .workspace_path => |workspace_failure| mcp_errors.workspacePath(allocator, tool_name, workspace_failure.path, context.workspace.root, error.PathOutsideWorkspace),
        else => commandFailureResult(allocator, context, tool_name, failure),
    };
}

fn commandFailureResult(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    tool_name: []const u8,
    failure: core_usecase.Failure,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (failure) {
        .argument => |app_error| appArgumentErrorResult(allocator, tool_name, app_error),
        .workspace_path => |workspace_failure| mcp_errors.workspacePath(allocator, tool_name, workspace_failure.path, context.workspace.root, workspace_failure.err),
        .command_run => |command_failure| blk: {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const value = commandErrorValue(arena.allocator(), command_failure) catch return error.OutOfMemory;
            break :blk mcp_result.structured(allocator, value);
        },
    };
}

fn appArgumentErrorResult(allocator: std.mem.Allocator, tool_name: []const u8, app_error: app_errors.AppError) mcp.tools.ToolError!mcp.tools.ToolResult {
    const field = app_error.field orelse "argument";
    const expected = app_error.expected orelse "valid argument";
    if (std.mem.eql(u8, app_error.code, "missing_required_argument")) {
        return mcp_errors.missingArgument(allocator, tool_name, field, expected);
    }
    return mcp_errors.invalidArgument(
        allocator,
        tool_name,
        field,
        expected,
        app_error.actual orelse "",
        app_error.resolution,
    );
}

fn commandResultValue(allocator: std.mem.Allocator, run: core_usecase.CommandRun) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const term = run.result.effectiveTerm();
    const ok = !term.failed() and !run.result.timed_out;
    try obj.put(allocator, "kind", .{ .string = "command" });
    try obj.put(allocator, "title", .{ .string = run.title });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "cwd", .{ .string = run.cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, run.argv.items));
    try obj.put(allocator, "timeout_ms", .{ .integer = run.timeout_ms });
    try obj.put(allocator, "duration_ms", .{ .integer = @intCast(run.result.duration_ms) });
    try obj.put(allocator, "term", try commandTermValue(allocator, term));
    const stdout = try safeTextAlloc(allocator, run.result.stdout);
    const stderr = try safeTextAlloc(allocator, run.result.stderr);
    try putStreamFields(allocator, &obj, "stdout", stdout);
    try putStreamFields(allocator, &obj, "stderr", stderr);
    try obj.put(allocator, "stdout_truncated", .{ .bool = run.result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = run.result.stderr_truncated });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(run.stdout_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(run.stderr_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = run.result.stdout_truncated or run.result.stderr_truncated });
    if (run.result.stdout_truncated or run.result.stderr_truncated) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigar's capture limit. zigar returned the captured prefix and marked the truncated stream so the result remains inspectable." });
    }
    const insights = try compilerInsightsValue(allocator, stdout.text, stderr.text, run.argv.items);
    try obj.put(allocator, "diagnostics", insights);
    try obj.put(allocator, "failure_summary", try failureSummaryValue(allocator, insights, ok, run.argv.items));
    return .{ .object = obj };
}

fn commandErrorValue(allocator: std.mem.Allocator, failure: core_usecase.CommandRunFailure) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "command_error" });
    try obj.put(allocator, "title", .{ .string = failure.title });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "cwd", .{ .string = failure.cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, failure.argv.items));
    try obj.put(allocator, "timeout_ms", .{ .integer = failure.timeout_ms });
    try obj.put(allocator, "error", .{ .string = @errorName(failure.err) });
    try obj.put(allocator, "error_kind", .{ .string = portErrorKind(failure.err) });
    try obj.put(allocator, "stdout_limit", .{ .integer = core_usecase.command_output_limit });
    try obj.put(allocator, "stderr_limit", .{ .integer = core_usecase.command_output_limit });
    try obj.put(allocator, "output_limit_mode", .{ .string = output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = isOutputLimitError(failure.err) });
    try obj.put(allocator, "stdout_truncated", .{ .bool = false });
    try obj.put(allocator, "stderr_truncated", .{ .bool = false });
    if (isOutputLimitError(failure.err)) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigar's capture limit before zigar could retain a bounded prefix. Narrow the command or run it directly when full output is needed." });
    }
    try obj.put(allocator, "failure_summary", try commandErrorSummaryValue(allocator, failure.err, failure.argv.items));
    return .{ .object = obj };
}

fn backendErrorResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(scratch);
    try obj.put(scratch, "kind", .{ .string = "backend_error" });
    try obj.put(scratch, "ok", .{ .bool = false });
    try obj.put(scratch, "backend", .{ .string = backend_name });
    try obj.put(scratch, "operation", .{ .string = operation });
    try obj.put(scratch, "error", .{ .string = @errorName(err) });
    try obj.put(scratch, "error_kind", .{ .string = backendErrorKind(err) });
    try obj.put(scratch, "resolution", .{ .string = resolution });
    return mcp_result.structured(allocator, .{ .object = obj });
}

fn compilerInsightsValue(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8, argv: []const []const u8) !std.json.Value {
    var findings = std.json.Array.init(allocator);
    var error_count: i64 = 0;
    var warning_count: i64 = 0;
    var note_count: i64 = 0;
    var primary: ?CompilerLine = null;

    try collectCompilerLines(allocator, &findings, stderr, &primary, &error_count, &warning_count, &note_count);
    try collectCompilerLines(allocator, &findings, stdout, &primary, &error_count, &warning_count, &note_count);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try obj.put(allocator, "error_count", .{ .integer = error_count });
    try obj.put(allocator, "warning_count", .{ .integer = warning_count });
    try obj.put(allocator, "note_count", .{ .integer = note_count });
    try obj.put(allocator, "findings", .{ .array = findings });
    if (primary) |p| {
        try obj.put(allocator, "primary", try compilerLineValue(allocator, p));
        try obj.put(allocator, "category", .{ .string = compiler_output.classifyDiagnosticMessage(p.message) });
        try obj.put(allocator, "next_command", try compilerNextCommand(allocator, p, argv));
        try obj.put(allocator, "next_actions", try compilerNextActions(allocator, p, note_count));
    } else {
        try obj.put(allocator, "primary", .null);
        try obj.put(allocator, "category", .{ .string = "none" });
        try obj.put(allocator, "next_command", .null);
        try obj.put(allocator, "next_actions", .{ .array = std.json.Array.init(allocator) });
    }
    return .{ .object = obj };
}

const CompilerLine = compiler_output.CompilerLine;

fn collectCompilerLines(
    allocator: std.mem.Allocator,
    findings: *std.json.Array,
    text_value: []const u8,
    primary: *?CompilerLine,
    error_count: *i64,
    warning_count: *i64,
    note_count: *i64,
) !void {
    var lines = std.mem.splitScalar(u8, text_value, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        const parsed = compiler_output.parseCompilerLine(line) orelse continue;
        if (std.mem.eql(u8, parsed.severity, "error")) {
            error_count.* += 1;
            if (primary.* == null) primary.* = parsed;
        } else if (std.mem.eql(u8, parsed.severity, "warning")) {
            warning_count.* += 1;
            if (primary.* == null) primary.* = parsed;
        } else if (std.mem.eql(u8, parsed.severity, "note")) {
            note_count.* += 1;
        }
        try findings.append(try compilerLineValue(allocator, parsed));
    }
}

fn compilerLineValue(allocator: std.mem.Allocator, parsed: CompilerLine) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "severity", .{ .string = parsed.severity });
    try obj.put(allocator, "message", try ownedString(allocator, parsed.message));
    try obj.put(allocator, "raw", try ownedString(allocator, parsed.raw));
    if (parsed.path) |path| {
        try obj.put(allocator, "path", try ownedString(allocator, path));
    } else {
        try obj.put(allocator, "path", .null);
    }
    if (parsed.line) |line_no| {
        try obj.put(allocator, "line", .{ .integer = line_no });
    } else {
        try obj.put(allocator, "line", .null);
    }
    if (parsed.column) |col_no| {
        try obj.put(allocator, "column", .{ .integer = col_no });
    } else {
        try obj.put(allocator, "column", .null);
    }
    return .{ .object = obj };
}

fn compilerNextCommand(allocator: std.mem.Allocator, primary: CompilerLine, argv: []const []const u8) !std.json.Value {
    const zig = if (argv.len > 0) argv[0] else "zig";
    const path = primary.path orelse return .{ .string = try commandString(allocator, argv) };
    if (path.len > 0 and std.mem.endsWith(u8, path, ".zig")) {
        if (argvContains(argv, "test")) {
            return .{ .string = try std.fmt.allocPrint(allocator, "{s} test {s}", .{ zig, path }) };
        }
        return .{ .string = try std.fmt.allocPrint(allocator, "{s} ast-check {s}", .{ zig, path }) };
    }
    return .{ .string = try commandString(allocator, argv) };
}

fn compilerNextActions(allocator: std.mem.Allocator, primary: CompilerLine, note_count: i64) !std.json.Value {
    var actions = std.json.Array.init(allocator);
    if (primary.path) |path| {
        if (primary.line) |line_no| {
            if (primary.column) |col_no| {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d}:{d} and address the primary {s}: {s}", .{ path, line_no, col_no, primary.severity, primary.message }) });
            } else {
                try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Open {s}:{d} and address the primary {s}: {s}", .{ path, line_no, primary.severity, primary.message }) });
            }
        } else {
            try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Inspect {s} and address the primary {s}: {s}", .{ path, primary.severity, primary.message }) });
        }
    } else {
        try actions.append(.{ .string = try std.fmt.allocPrint(allocator, "Address the primary {s}: {s}", .{ primary.severity, primary.message }) });
    }
    if (note_count > 0) {
        try actions.append(try ownedString(allocator, "Review compiler note entries before editing; Zig often puts the fix-relevant type or declaration context there."));
    }
    if (std.mem.eql(u8, compiler_output.classifyDiagnosticMessage(primary.message), "missing_file_or_import")) {
        try actions.append(try ownedString(allocator, "Run zig_import_resolve for the failing @import name, then check build.zig addImport and build.zig.zon dependency wiring."));
    }
    try actions.append(try ownedString(allocator, "Rerun the next_command after the focused edit."));
    return .{ .array = actions };
}

fn failureSummaryValue(allocator: std.mem.Allocator, insights: std.json.Value, ok: bool, argv: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = ok });
    const insights_obj = switch (insights) {
        .object => |o| o,
        else => {
            try obj.put(allocator, "primary", .null);
            return .{ .object = obj };
        },
    };
    const primary = insights_obj.get("primary") orelse .null;
    try obj.put(allocator, "primary", primary);
    try obj.put(allocator, "error_class", insights_obj.get("category") orelse .{ .string = "none" });
    try obj.put(allocator, "rerun_command", insights_obj.get("next_command") orelse .null);
    var suggested = std.json.Array.init(allocator);
    if (!ok) {
        try suggested.append(try ownedString(allocator, "zig_compile_error_index"));
        if (argvContains(argv, "test")) try suggested.append(try ownedString(allocator, "zig_test_failure_triage"));
        try suggested.append(try ownedString(allocator, "zigar_failure_fusion"));
        try suggested.append(try ownedString(allocator, "zigar_impact"));
    }
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", try likelyFailureScopeValue(allocator, primary));
    return .{ .object = obj };
}

fn commandErrorSummaryValue(allocator: std.mem.Allocator, err: ports.PortError, argv: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "primary", .null);
    try obj.put(allocator, "error_class", .{ .string = portErrorKind(err) });
    try obj.put(allocator, "rerun_command", .{ .string = try commandString(allocator, argv) });
    var suggested = std.json.Array.init(allocator);
    try suggested.append(try ownedString(allocator, "zigar_doctor"));
    try suggested.append(try ownedString(allocator, "zigar_context_pack"));
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", .{ .string = if (isTimeoutError(err)) "command_timeout" else "tool_or_backend_configuration" });
    return .{ .object = obj };
}

fn likelyFailureScopeValue(allocator: std.mem.Allocator, primary: std.json.Value) !std.json.Value {
    const primary_obj = switch (primary) {
        .object => |o| o,
        else => return .{ .string = "none" },
    };
    const path = switch (primary_obj.get("path") orelse .null) {
        .string => |s| s,
        else => return .{ .string = "workspace_or_build" },
    };
    if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) return .{ .string = "build_configuration" };
    if (std.mem.endsWith(u8, path, ".zig")) return .{ .string = "source_file" };
    return .{ .string = try std.fmt.allocPrint(allocator, "path:{s}", .{path}) };
}

fn commandTermValue(allocator: std.mem.Allocator, term: ports.CommandTerm) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    switch (term) {
        .exited => |code| {
            try obj.put(allocator, "kind", .{ .string = "exited" });
            try obj.put(allocator, "code", .{ .integer = @intCast(code) });
        },
        .signal => try obj.put(allocator, "kind", .{ .string = "signal" }),
        .stopped => try obj.put(allocator, "kind", .{ .string = "stopped" }),
        .unknown => try obj.put(allocator, "kind", .{ .string = "unknown" }),
    }
    return .{ .object = obj };
}

fn safeTextAlloc(allocator: std.mem.Allocator, bytes: []const u8) !struct {
    text: []const u8,
    invalid_utf8: bool,
    encoding: []const u8,
    byte_count: usize,
} {
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return .{
            .text = try allocator.dupe(u8, bytes),
            .invalid_utf8 = false,
            .encoding = "utf-8",
            .byte_count = bytes.len,
        };
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
            try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
            continue;
        };
        if (index + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[index .. index + len])) {
            try out.appendSlice(allocator, bytes[index .. index + len]);
            index += len;
        } else {
            try out.appendSlice(allocator, &std.unicode.replacement_character_utf8);
            index += 1;
        }
    }

    return .{
        .text = try out.toOwnedSlice(allocator),
        .invalid_utf8 = true,
        .encoding = "utf-8-lossy",
        .byte_count = bytes.len,
    };
}

fn putStreamFields(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, name: []const u8, safe: anytype) !void {
    try obj.put(allocator, name, .{ .string = safe.text });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_invalid_utf8", .{name}), .{ .bool = safe.invalid_utf8 });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_encoding", .{name}), .{ .string = safe.encoding });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_byte_count", .{name}), .{ .integer = @intCast(safe.byte_count) });
}

fn argvValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (argv) |arg| try array.append(.{ .string = arg });
    return .{ .array = array };
}

fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

fn commandString(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    if (argv.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

fn argvContains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

fn splitArgs(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
        current.deinit(allocator);
    }

    var quote: ?u8 = null;
    var escaping = false;
    var in_token = false;
    for (text) |c| {
        if (escaping) {
            try current.append(allocator, c);
            in_token = true;
            escaping = false;
            continue;
        }
        if (c == '\\') {
            escaping = true;
            in_token = true;
            continue;
        }
        if (quote) |q| {
            if (c == q) {
                quote = null;
            } else {
                try current.append(allocator, c);
            }
            in_token = true;
            continue;
        }
        switch (c) {
            '\'', '"' => {
                quote = c;
                in_token = true;
            },
            ' ', '\t', '\r', '\n' => {
                if (in_token) {
                    try finishArg(allocator, &list, &current);
                    in_token = false;
                }
            },
            else => {
                try current.append(allocator, c);
                in_token = true;
            },
        }
    }
    if (escaping or quote != null) return error.InvalidArguments;
    if (in_token) try finishArg(allocator, &list, &current);
    return list.toOwnedSlice(allocator);
}

fn finishArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), current: *std.ArrayList(u8)) !void {
    const arg = try current.toOwnedSlice(allocator);
    errdefer allocator.free(arg);
    try list.append(allocator, arg);
}

fn freeArgList(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn splitToolArgsError(allocator: std.mem.Allocator, tool_name: []const u8, field: []const u8, actual: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return switch (err) {
        error.InvalidArguments => mcp_errors.invalidArgument(
            allocator,
            tool_name,
            field,
            "shell-style argument string",
            actual,
            "Quote arguments the same way you would in a shell command, or omit the field when no extra arguments are needed.",
        ),
        error.OutOfMemory => error.OutOfMemory,
        else => mcp_errors.fromError(allocator, .{
            .tool = tool_name,
            .operation = "parse_arguments",
            .phase = "split_extra_arguments",
            .code = "argument_parse_failed",
            .category = "argument",
            .resolution = "Inspect the extra argument string and retry with valid shell-style quoting.",
            .details = &.{
                .{ .key = "field", .value = .{ .string = field } },
                .{ .key = "actual", .value = .{ .string = actual } },
            },
        }, err),
    };
}

fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    return mcp.tools.getString(args, name);
}

fn argInteger(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    return mcp.tools.getInteger(args, name) orelse default;
}

fn toolTimeout(context: app_context.CoreCommandContext, args: ?std.json.Value) i64 {
    return @max(1, @min(argInteger(args, "timeout_ms", context.timeouts.command_ms), 60 * 60 * 1000));
}

fn commandOk(result: ports.CommandResult) bool {
    return !result.effectiveTerm().failed() and !result.timed_out;
}

fn portErrorKind(err: anyerror) []const u8 {
    return switch (err) {
        error.Timeout, error.RequestTimeout => "timeout",
        error.StreamTooLong, error.OutputLimitExceeded => "output_limit",
        error.FileNotFound => "executable_not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        else => "execution",
    };
}

fn backendErrorKind(err: anyerror) []const u8 {
    return switch (err) {
        error.RequestTimeout, error.Timeout => "timeout",
        error.NotConnected, error.EndOfStream, error.BrokenPipe => "unavailable",
        error.FileNotFound => "executable_not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        error.StreamTooLong, error.OutputLimitExceeded => "output_limit",
        else => portErrorKind(err),
    };
}

fn isOutputLimitError(err: anyerror) bool {
    return err == error.StreamTooLong or err == error.OutputLimitExceeded;
}

fn isTimeoutError(err: anyerror) bool {
    return err == error.Timeout or err == error.RequestTimeout;
}
