const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const command = zigar.command;
const doctor = zigar.doctor;
const json_result = zigar.json_result;
const runtime_mod = zigar.runtime;

pub const App = runtime_mod.App;
pub const BackendProbeCache = runtime_mod.BackendProbeCache;
pub const LspClient = zigar.lsp_client.LspClient;

pub fn errorText(allocator: std.mem.Allocator, value: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return mcp.tools.errorResult(allocator, value) catch return error.OutOfMemory;
}

pub fn structured(allocator: std.mem.Allocator, value: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return json_result.structured(allocator, value);
}

pub fn structuredOwned(allocator: std.mem.Allocator, value: std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return json_result.structuredOwned(allocator, value);
}

pub fn putOwnedKey(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8, value: std.json.Value) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try obj.put(allocator, owned_key, value);
}

pub fn argString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    return mcp.tools.getString(args, name);
}

pub fn argBool(args: ?std.json.Value, name: []const u8, default: bool) bool {
    return mcp.tools.getBoolean(args, name) orelse default;
}

pub fn argInt(args: ?std.json.Value, name: []const u8, default: i64) i64 {
    return mcp.tools.getInteger(args, name) orelse default;
}

pub fn workspacePathErrorResult(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    switch (err) {
        error.PathOutsideWorkspace, error.EmptyPath => {
            const message = workspacePathErrorMessage(allocator, tool_name, path, a.workspace.root, err) catch return error.OutOfMemory;
            defer allocator.free(message);
            return errorText(allocator, message);
        },
        error.InvalidArguments => return error.InvalidArguments,
        error.NotConnected => return zlsUnavailable(a, allocator),
        error.DocumentTooLarge => return errorText(allocator, "ZLS document sync rejected content larger than zigar's per-document memory budget. Save the file on disk and call a file-based tool, or send a smaller unsaved document."),
        error.OpenDocumentLimitExceeded => return errorText(allocator, "ZLS document sync rejected the document because zigar reached its open-document budget. Close unused documents with zig_document_close and retry."),
        error.ExecutionFailed => return error.ExecutionFailed,
        else => {
            const message = std.fmt.allocPrint(
                allocator,
                "{s}: rejected path `{s}` while resolving it inside the configured workspace: {s}.",
                .{ tool_name, path, @errorName(err) },
            ) catch return error.OutOfMemory;
            defer allocator.free(message);
            return errorText(allocator, message);
        },
    }
}

pub fn workspacePathErrorMessage(allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8, root: []const u8, err: anyerror) ![]u8 {
    if (err == error.EmptyPath) {
        return std.fmt.allocPrint(
            allocator,
            "{s}: rejected an empty path.\n\nRun zigar_workspace_info to confirm the active workspace `{s}`. Pass a workspace-relative path, or restart/configure zigar with --workspace set to the Zig project you are editing.",
            .{ tool_name, root },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}: rejected path `{s}` because it is outside the configured zigar workspace `{s}`.\n\nRun zigar_workspace_info to confirm the active workspace. Pass a workspace-relative path, or restart/configure zigar with --workspace set to the Zig project you are editing.",
        .{ tool_name, path, root },
    );
}

pub fn runAndFormat(a: *App, allocator: std.mem.Allocator, argv: []const []const u8, title: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runAndFormatTimeout(a, allocator, argv, title, a.config.timeout_ms);
}

pub fn runAndFormatTimeout(a: *App, allocator: std.mem.Allocator, argv: []const []const u8, title: []const u8, timeout_ms: i64) mcp.tools.ToolError!mcp.tools.ToolResult {
    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, argv, timeout_ms) catch |err| {
        a.tool_errors += 1;
        const value = commandErrorValue(allocator, title, argv, a.workspace.root, timeout_ms, err) catch return error.OutOfMemory;
        return structured(allocator, value);
    };
    defer result.deinit(allocator);
    const value = commandResultValue(allocator, title, argv, a.workspace.root, timeout_ms, result) catch return error.OutOfMemory;
    return structured(allocator, value);
}

pub fn toolTimeout(a: *App, args: ?std.json.Value) i64 {
    return @max(1, @min(argInt(args, "timeout_ms", a.config.timeout_ms), 60 * 60 * 1000));
}

pub fn argvValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (argv) |arg| try array.append(.{ .string = arg });
    return .{ .array = array };
}

pub fn commandTermValue(allocator: std.mem.Allocator, term: std.process.Child.Term) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    switch (term) {
        .exited => |code| {
            try obj.put(allocator, "kind", .{ .string = "exited" });
            try obj.put(allocator, "code", .{ .integer = @intCast(code) });
        },
        .signal => {
            try obj.put(allocator, "kind", .{ .string = "signal" });
        },
        .stopped => {
            try obj.put(allocator, "kind", .{ .string = "stopped" });
        },
        .unknown => {
            try obj.put(allocator, "kind", .{ .string = "unknown" });
        },
    }
    return .{ .object = obj };
}

pub fn commandResultValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, result: command.RunResult) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "command" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = result.succeeded() });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "term", try commandTermValue(allocator, result.term));
    try obj.put(allocator, "stdout", .{ .string = result.stdout });
    try obj.put(allocator, "stderr", .{ .string = result.stderr });
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(result.stdout_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(result.stderr_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = command.output_limit_mode });
    const insights = try compilerInsightsValue(allocator, result.stdout, result.stderr, argv);
    try obj.put(allocator, "diagnostics", insights);
    try obj.put(allocator, "failure_summary", try failureSummaryValue(allocator, insights, result.succeeded(), argv));
    return .{ .object = obj };
}

pub fn commandErrorValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, err: anyerror) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "command_error" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = command.errorKind(err) });
    try obj.put(allocator, "stdout_limit", .{ .integer = command.output_limit });
    try obj.put(allocator, "stderr_limit", .{ .integer = command.output_limit });
    try obj.put(allocator, "output_limit_mode", .{ .string = command.output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = command.isOutputLimitError(err) });
    try obj.put(allocator, "stdout_truncated", .{ .bool = false });
    try obj.put(allocator, "stderr_truncated", .{ .bool = false });
    if (command.isOutputLimitError(err)) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigar's capture limit. zigar fails the command instead of returning partial output; narrow the command or run it directly when full output is needed." });
    }
    try obj.put(allocator, "failure_summary", try commandErrorSummaryValue(allocator, err, argv));
    return .{ .object = obj };
}

pub fn failureSummaryValue(allocator: std.mem.Allocator, insights: std.json.Value, ok: bool, argv: []const []const u8) !std.json.Value {
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

pub fn commandErrorSummaryValue(allocator: std.mem.Allocator, err: anyerror, argv: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "primary", .null);
    try obj.put(allocator, "error_class", .{ .string = command.errorKind(err) });
    try obj.put(allocator, "rerun_command", .{ .string = try commandString(allocator, argv) });
    var suggested = std.json.Array.init(allocator);
    try suggested.append(try ownedString(allocator, "zigar_doctor"));
    try suggested.append(try ownedString(allocator, "zigar_context_pack"));
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", .{ .string = if (command.isTimeoutError(err)) "command_timeout" else "tool_or_backend_configuration" });
    return .{ .object = obj };
}

pub fn likelyFailureScopeValue(allocator: std.mem.Allocator, primary: std.json.Value) !std.json.Value {
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

pub fn backendErrorKind(err: anyerror) []const u8 {
    return switch (err) {
        error.RequestTimeout, error.Timeout => "timeout",
        error.NotConnected, error.EndOfStream, error.BrokenPipe => "unavailable",
        error.FileNotFound => "executable_not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        error.StreamTooLong => "output_limit",
        else => command.errorKind(err),
    };
}

pub fn backendErrorValue(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = backendErrorKind(err) });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return .{ .object = obj };
}

pub fn backendErrorResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, backendErrorValue(allocator, backend_name, operation, err, resolution) catch return error.OutOfMemory);
}

pub fn backendUnavailableResult(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, configured_path: []const u8, status: []const u8, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = "Unavailable" });
    try obj.put(allocator, "error_kind", .{ .string = "unavailable" });
    try obj.put(allocator, "configured_path", .{ .string = configured_path });
    try obj.put(allocator, "status", .{ .string = status });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return structured(allocator, .{ .object = obj });
}

pub fn splitToolArgs(allocator: std.mem.Allocator, text_value: ?[]const u8) mcp.tools.ToolError![]const []const u8 {
    return command.splitArgs(allocator, text_value) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidArguments => error.InvalidArguments,
    };
}

pub const CompilerLine = struct {
    severity: []const u8,
    path: ?[]const u8 = null,
    line: ?i64 = null,
    column: ?i64 = null,
    message: []const u8,
    raw: []const u8,
};

pub fn compilerInsightsValue(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8, argv: []const []const u8) !std.json.Value {
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
        try obj.put(allocator, "category", .{ .string = classifyDiagnosticMessage(p.message) });
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

pub fn collectCompilerLines(
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
        const parsed = parseCompilerLine(line) orelse continue;
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

pub fn parseCompilerLine(line: []const u8) ?CompilerLine {
    if (parseLocatedCompilerLine(line, "error")) |parsed| return parsed;
    if (parseLocatedCompilerLine(line, "warning")) |parsed| return parsed;
    if (parseLocatedCompilerLine(line, "note")) |parsed| return parsed;
    if (std.mem.startsWith(u8, line, "error: ")) return .{ .severity = "error", .message = line["error: ".len..], .raw = line };
    if (std.mem.startsWith(u8, line, "warning: ")) return .{ .severity = "warning", .message = line["warning: ".len..], .raw = line };
    if (std.mem.startsWith(u8, line, "note: ")) return .{ .severity = "note", .message = line["note: ".len..], .raw = line };
    return null;
}

pub fn parseLocatedCompilerLine(line: []const u8, severity: []const u8) ?CompilerLine {
    var token_buf: [16]u8 = undefined;
    const token = std.fmt.bufPrint(&token_buf, ": {s}: ", .{severity}) catch return null;
    const severity_pos = std.mem.indexOf(u8, line, token) orelse return null;
    const prefix = line[0..severity_pos];
    const message = line[severity_pos + token.len ..];
    const col_sep = std.mem.lastIndexOfScalar(u8, prefix, ':') orelse return .{ .severity = severity, .message = message, .raw = line };
    const line_prefix = prefix[0..col_sep];
    const line_sep = std.mem.lastIndexOfScalar(u8, line_prefix, ':') orelse return .{ .severity = severity, .message = message, .raw = line };
    const line_no = std.fmt.parseInt(i64, line_prefix[line_sep + 1 ..], 10) catch return .{ .severity = severity, .message = message, .raw = line };
    const col_no = std.fmt.parseInt(i64, prefix[col_sep + 1 ..], 10) catch return .{ .severity = severity, .message = message, .raw = line };
    return .{
        .severity = severity,
        .path = line_prefix[0..line_sep],
        .line = line_no,
        .column = col_no,
        .message = message,
        .raw = line,
    };
}

pub fn compilerLineValue(allocator: std.mem.Allocator, parsed: CompilerLine) !std.json.Value {
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

pub fn classifyDiagnosticMessage(message: []const u8) []const u8 {
    if (std.mem.indexOf(u8, message, "expected type") != null) return "type_mismatch";
    if (std.mem.indexOf(u8, message, "expected ") != null and std.mem.indexOf(u8, message, "found ") != null) return "syntax_or_type_mismatch";
    if (std.mem.indexOf(u8, message, "expected ") != null) return "syntax_error";
    if (std.mem.indexOf(u8, message, "use of undeclared identifier") != null) return "undeclared_identifier";
    if (std.mem.indexOf(u8, message, "no field named") != null) return "missing_field";
    if (std.mem.indexOf(u8, message, "unable to load") != null or std.mem.indexOf(u8, message, "FileNotFound") != null) return "missing_file_or_import";
    if (std.mem.indexOf(u8, message, "unused") != null) return "unused_code";
    if (std.mem.indexOf(u8, message, "invalid token") != null) return "syntax_error";
    return "compiler_error";
}

pub fn compilerNextCommand(allocator: std.mem.Allocator, primary: CompilerLine, argv: []const []const u8) !std.json.Value {
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

pub fn compilerNextActions(allocator: std.mem.Allocator, primary: CompilerLine, note_count: i64) !std.json.Value {
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
    if (std.mem.eql(u8, classifyDiagnosticMessage(primary.message), "missing_file_or_import")) {
        try actions.append(try ownedString(allocator, "Run zig_import_resolve for the failing @import name, then check build.zig addImport and build.zig.zon dependency wiring."));
    }
    try actions.append(try ownedString(allocator, "Rerun the next_command after the focused edit."));
    return .{ .array = actions };
}

pub fn commandString(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    if (argv.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

pub fn argvContains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, needle)) return true;
    }
    return false;
}

pub fn structuredText(allocator: std.mem.Allocator, kind: []const u8, body: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "kind", .{ .string = kind }) catch return error.OutOfMemory;
    obj.put(allocator, "text", .{ .string = body }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn jsonTextOnly(allocator: std.mem.Allocator, bytes: []u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    errdefer allocator.free(bytes);
    const content = allocator.alloc(mcp.types.ContentBlock, 1) catch return error.OutOfMemory;
    content[0] = .{ .text = .{ .text = bytes } };
    return .{ .content = content };
}

pub fn probeBackend(a: *App, allocator: std.mem.Allocator, name: []const u8, argv: []const []const u8, timeout_ms: i64) doctor.Probe {
    if (backendProbeSlot(a, name)) |slot| {
        if (slot.*) |probe| return probe;
        const probe = probeBackendDirect(allocator, a, argv, timeout_ms);
        slot.* = probe;
        return probe;
    }
    return probeBackendDirect(allocator, a, argv, timeout_ms);
}

pub fn backendProbeSlot(a: *App, name: []const u8) ?*?doctor.Probe {
    if (std.mem.eql(u8, name, "zig")) return &a.backend_probe_cache.zig;
    if (std.mem.eql(u8, name, "zls")) return &a.backend_probe_cache.zls;
    if (std.mem.eql(u8, name, "zwanzig")) return &a.backend_probe_cache.zwanzig;
    if (std.mem.eql(u8, name, "zflame")) return &a.backend_probe_cache.zflame;
    if (std.mem.eql(u8, name, "diff-folded")) return &a.backend_probe_cache.diff_folded;
    return null;
}

pub fn probeBackendDirect(allocator: std.mem.Allocator, a: *App, argv: []const []const u8, timeout_ms: i64) doctor.Probe {
    const result = command.run(allocator, a.io, a.workspace.root, argv, timeout_ms) catch |err| {
        return .{ .ok = false, .status = @errorName(err), .resolution = "confirm the configured backend path and executable permissions" };
    };
    defer result.deinit(allocator);
    if (result.succeeded()) {
        return .{ .ok = true, .status = "ok", .resolution = "backend command completed" };
    }
    return .{ .ok = false, .status = command.termText(result.term), .resolution = "backend command exited non-zero; run the configured command directly to inspect stderr" };
}

pub fn backendProbeCacheValue(allocator: std.mem.Allocator, cache: BackendProbeCache) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig", try cachedProbeValue(allocator, cache.zig));
    try obj.put(allocator, "zls", try cachedProbeValue(allocator, cache.zls));
    try obj.put(allocator, "zwanzig", try cachedProbeValue(allocator, cache.zwanzig));
    try obj.put(allocator, "zflame", try cachedProbeValue(allocator, cache.zflame));
    try obj.put(allocator, "diff_folded", try cachedProbeValue(allocator, cache.diff_folded));
    return .{ .object = obj };
}

pub fn cachedProbeValue(allocator: std.mem.Allocator, probe: ?doctor.Probe) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    if (probe) |p| {
        try obj.put(allocator, "probed", .{ .bool = true });
        try obj.put(allocator, "ok", .{ .bool = p.ok });
        try obj.put(allocator, "status", .{ .string = p.status });
        try obj.put(allocator, "resolution", .{ .string = p.resolution });
    } else {
        try obj.put(allocator, "probed", .{ .bool = false });
        try obj.put(allocator, "ok", .null);
        try obj.put(allocator, "status", .{ .string = "not probed" });
        try obj.put(allocator, "resolution", .{ .string = "call zigar_doctor with probe_backends=true to cache backend availability" });
    }
    return .{ .object = obj };
}

pub fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}
pub fn statusLinePath(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, if (line.len > 3) line[3..] else "", " \t");
    if (std.mem.indexOf(u8, trimmed, " -> ")) |arrow| return trimmed[arrow + " -> ".len ..];
    return trimmed;
}

pub fn workspacePathExists(allocator: std.mem.Allocator, a: *App, path: []const u8) bool {
    const resolved = a.workspace.resolve(path) catch return false;
    defer allocator.free(resolved);
    var dir = std.Io.Dir.openDirAbsolute(a.io, resolved, .{}) catch {
        if (std.Io.Dir.cwd().readFileAlloc(a.io, resolved, allocator, .limited(1)) catch null) |bytes| {
            allocator.free(bytes);
            return true;
        }
        return false;
    };
    dir.close(a.io);
    return true;
}

pub fn changedPathList(allocator: std.mem.Allocator, a: *App, explicit_files: ?[]const u8, timeout_ms: i64) !std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        freeStringList(allocator, list.items);
        list.deinit(allocator);
    }
    try appendPathTokens(allocator, &list, explicit_files);
    if (list.items.len > 0) return list;
    const result = command.run(allocator, a.io, a.workspace.root, &.{ "git", "status", "--porcelain" }, @min(timeout_ms, 5000)) catch return list;
    defer result.deinit(allocator);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const path = statusLinePath(line);
        if (path.len == 0 or analysis.skipWorkspacePath(path)) continue;
        try appendUniqueString(allocator, &list, path);
    }
    return list;
}

pub fn appendPathTokens(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), text_value: ?[]const u8) !void {
    const text_input = text_value orelse return;
    var tokens = std.mem.tokenizeAny(u8, text_input, ", \t\r\n");
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        try appendUniqueString(allocator, list, token);
    }
}

pub fn appendPatchPaths(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), patch_text: ?[]const u8) !void {
    const patch = patch_text orelse return;
    var lines = std.mem.splitScalar(u8, patch, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (std.mem.startsWith(u8, trimmed, "+++ ")) {
            try appendPatchPathToken(allocator, list, std.mem.trim(u8, trimmed["+++ ".len..], " \t"));
        } else if (std.mem.startsWith(u8, trimmed, "--- ")) {
            try appendPatchPathToken(allocator, list, std.mem.trim(u8, trimmed["--- ".len..], " \t"));
        } else if (std.mem.startsWith(u8, trimmed, "diff --git ")) {
            var parts = std.mem.tokenizeScalar(u8, trimmed, ' ');
            _ = parts.next();
            _ = parts.next();
            if (parts.next()) |left| try appendPatchPathToken(allocator, list, left);
            if (parts.next()) |right| try appendPatchPathToken(allocator, list, right);
        }
    }
}

pub fn appendPatchPathToken(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), raw: []const u8) !void {
    var path = raw;
    if (std.mem.startsWith(u8, path, "a/") or std.mem.startsWith(u8, path, "b/")) path = path[2..];
    if (std.mem.eql(u8, path, "/dev/null")) return;
    try appendUniqueString(allocator, list, path);
}

pub fn appendUniqueString(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    if (stringListContains(list.items, value)) return;
    try list.append(allocator, try allocator.dupe(u8, value));
}

pub fn stringListContains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, value)) return true;
    }
    return false;
}

pub fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
}

pub fn jsonArrayLen(value: std.json.Value) usize {
    return switch (value) {
        .array => |a| a.items.len,
        else => 0,
    };
}

pub fn asciiLowerAllocLocal(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, input);
    for (out) |*ch| ch.* = std.ascii.toLower(ch.*);
    return out;
}

pub fn lineNumberLocal(text_value: []const u8, index: usize) usize {
    var line: usize = 1;
    for (text_value[0..@min(index, text_value.len)]) |ch| {
        if (ch == '\n') line += 1;
    }
    return line;
}

pub fn lineAtLocal(text_value: []const u8, index: usize) []const u8 {
    const safe_index = @min(index, text_value.len);
    const start = std.mem.lastIndexOfScalar(u8, text_value[0..safe_index], '\n') orelse 0;
    const end = std.mem.indexOfScalarPos(u8, text_value, safe_index, '\n') orelse text_value.len;
    return std.mem.trim(u8, text_value[if (start == 0) 0 else start + 1..end], " \t\r\n");
}

pub fn zlsUnavailable(a: *App, allocator: std.mem.Allocator) mcp.tools.ToolError!mcp.tools.ToolResult {
    return backendUnavailableResult(
        allocator,
        "zls",
        "lsp_session",
        a.config.zls_path,
        a.zls_status,
        "confirm --zls-path points to a ZLS build compatible with the configured Zig version, then restart the MCP client",
    );
}
