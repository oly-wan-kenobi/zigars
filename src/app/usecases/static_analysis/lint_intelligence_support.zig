//! Implementation helpers for the lint-intelligence use cases: command
//! execution result/error shaping, compiler-output insight extraction, finding
//! normalization, fingerprinting, and JSON serialization. Extracted from
//! lint_intelligence.zig so the orchestrator module stays focused. Leaf layer:
//! it never calls the public orchestrators.
const std = @import("std");
const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const compiler_output = @import("../../../domain/zig/compiler_output.zig");

/// Error set shared by the lint use cases: port failures plus a missing
/// command runner. Defined here because the extracted command helpers need it;
/// re-exported from lint_intelligence.zig for the public surface.
pub const LintError = ports.PortError || error{
    MissingCommandRunner,
};

/// Per-stream (stdout/stderr) capture cap for backend command output, in bytes.
pub const command_output_limit: usize = 1024 * 1024;
/// Reported policy when output hits the cap: the captured prefix is kept and the
/// stream is flagged truncated rather than failing the run.
pub const command_output_limit_mode = "truncate_on_limit";

/// Implements require command runner workflow logic using caller-owned inputs.
pub fn requireCommandRunner(context: app_context.StaticAnalysisContext) LintError!ports.CommandRunner {
    return context.command_runner orelse error.MissingCommandRunner;
}

/// Converts timing input into the duration unit used by result payloads.
pub fn commandTimeout(context: app_context.StaticAnalysisContext, requested_timeout_ms: ?u64) u64 {
    if (requested_timeout_ms) |value| return @max(value, 1);
    return @intCast(@max(context.timeouts.command_ms, 1));
}

/// Serializes backend error fields into an allocator-owned JSON value; allocation failures propagate.
pub fn backendErrorValue(allocator: std.mem.Allocator, backend_name: []const u8, operation: []const u8, err: anyerror, resolution: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend_name });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = backendErrorKind(err) });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return .{ .object = obj };
}

/// Implements backend error kind workflow logic using caller-owned inputs.
pub fn backendErrorKind(err: anyerror) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (err) {
        error.RequestTimeout, error.Timeout => "timeout",
        error.FileNotFound => "executable_not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        error.OutputLimitExceeded, error.StreamTooLong => "output_limit",
        error.Unavailable, error.EndOfStream, error.BrokenPipe => "unavailable",
        else => "execution",
    };
}

/// Serializes graph command failed fields into an allocator-owned JSON value; allocation failures propagate.
pub fn graphCommandFailedValue(allocator: std.mem.Allocator, argv: []const []const u8, cwd: []const u8, timeout_ms: u64, result: ports.CommandResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const command_text = try commandString(allocator, argv);
    const stdout = try safeTextAlloc(allocator, result.stdout);
    const stderr = try safeTextAlloc(allocator, result.stderr);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "tool_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "tool", .{ .string = "zig_analysis_graphs" });
    try obj.put(allocator, "operation", .{ .string = "generate_analysis_graphs" });
    try obj.put(allocator, "phase", .{ .string = "run_zwanzig_graph" });
    try obj.put(allocator, "code", .{ .string = "zwanzig_graph_command_failed" });
    try obj.put(allocator, "category", .{ .string = "backend" });
    try obj.put(allocator, "retryable", .{ .bool = false });
    try obj.put(allocator, "resolution", .{ .string = "Inspect stdout/stderr, confirm the selected graph mode is supported by the configured zwanzig binary, and retry." });
    try obj.put(allocator, "backend", .{ .string = "zwanzig" });
    try obj.put(allocator, "command", .{ .string = command_text });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "timeout_ms", .{ .integer = @intCast(timeout_ms) });
    try obj.put(allocator, "term", .{ .string = result.effectiveTerm().name() });
    try obj.put(allocator, "exit_code", if (result.effectiveTerm().exitCode()) |code| .{ .integer = code } else .null);
    try obj.put(allocator, "stdout", .{ .string = stdout.text });
    try obj.put(allocator, "stderr", .{ .string = stderr.text });
    try obj.put(allocator, "stdout_invalid_utf8", .{ .bool = stdout.invalid_utf8 });
    try obj.put(allocator, "stderr_invalid_utf8", .{ .bool = stderr.invalid_utf8 });
    try obj.put(allocator, "stdout_encoding", .{ .string = stdout.encoding });
    try obj.put(allocator, "stderr_encoding", .{ .string = stderr.encoding });
    try obj.put(allocator, "stdout_byte_count", .{ .integer = @intCast(stdout.byte_count) });
    try obj.put(allocator, "stderr_byte_count", .{ .integer = @intCast(stderr.byte_count) });
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "output_limit_mode", .{ .string = command_output_limit_mode });
    return .{ .object = obj };
}

/// Serializes graph output inspect error fields into an allocator-owned JSON value; allocation failures propagate.
pub fn graphOutputInspectErrorValue(allocator: std.mem.Allocator, output: []const u8, err: anyerror) !std.json.Value {
    var obj = try graphOutputBaseErrorValue(allocator, output, "inspect_output_directory", "backend_output_malformed", "Confirm zwanzig wrote DOT graph files to the requested workspace output directory.");
    try obj.object.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.object.put(allocator, "error_kind", .{ .string = backendErrorKind(err) });
    return obj;
}

/// Serializes graph output missing fields into an allocator-owned JSON value; allocation failures propagate.
pub fn graphOutputMissingValue(allocator: std.mem.Allocator, output: []const u8) !std.json.Value {
    return graphOutputBaseErrorValue(allocator, output, "inspect_output_directory", "backend_output_malformed", "The zwanzig command completed but no .dot graph files were found in the requested output directory.");
}

/// Serializes graph output base error fields into an allocator-owned JSON value; allocation failures propagate.
pub fn graphOutputBaseErrorValue(allocator: std.mem.Allocator, output: []const u8, phase: []const u8, code: []const u8, resolution: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "tool_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "tool", .{ .string = "zig_analysis_graphs" });
    try obj.put(allocator, "operation", .{ .string = "verify_graph_output" });
    try obj.put(allocator, "phase", .{ .string = phase });
    try obj.put(allocator, "code", .{ .string = code });
    try obj.put(allocator, "category", .{ .string = "backend_output" });
    try obj.put(allocator, "retryable", .{ .bool = false });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    try obj.put(allocator, "output", try ownedString(allocator, output));
    return .{ .object = obj };
}

/// Serializes command result fields into an allocator-owned JSON value; allocation failures propagate.
pub fn commandResultValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: u64, result: ports.CommandResult) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const term = result.effectiveTerm();
    const ok = !term.failed() and !result.timed_out;
    const stdout = try safeTextAlloc(allocator, result.stdout);
    const stderr = try safeTextAlloc(allocator, result.stderr);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "command" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = @intCast(timeout_ms) });
    try obj.put(allocator, "duration_ms", .{ .integer = @intCast(result.duration_ms) });
    try obj.put(allocator, "term", try commandTermValue(allocator, term));
    try putStreamFields(allocator, &obj, "stdout", stdout);
    try putStreamFields(allocator, &obj, "stderr", stderr);
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(command_output_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(command_output_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = command_output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = result.stdout_truncated or result.stderr_truncated });
    if (result.stdout_truncated or result.stderr_truncated) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigars' capture limit. zigars returned the captured prefix and marked the truncated stream so the result remains inspectable." });
    }
    const insights = try compilerInsightsValue(allocator, stdout.text, stderr.text, argv);
    try obj.put(allocator, "diagnostics", insights);
    try obj.put(allocator, "failure_summary", try failureSummaryValue(allocator, insights, ok, argv));
    return .{ .object = obj };
}

/// Serializes command error fields into an allocator-owned JSON value; allocation failures propagate.
pub fn commandErrorValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: u64, err: ports.PortError) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "command_error" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = @intCast(timeout_ms) });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = backendErrorKind(err) });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(command_output_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(command_output_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = command_output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = err == error.OutputLimitExceeded or err == error.StreamTooLong });
    try obj.put(allocator, "stdout_truncated", .{ .bool = false });
    try obj.put(allocator, "stderr_truncated", .{ .bool = false });
    try obj.put(allocator, "failure_summary", try commandErrorSummaryValue(allocator, err, argv));
    return .{ .object = obj };
}

/// Serializes command term fields into an allocator-owned JSON value; allocation failures propagate.
pub fn commandTermValue(allocator: std.mem.Allocator, term: ports.CommandTerm) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
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

/// Serializes compiler insights fields into an allocator-owned JSON value; allocation failures propagate.
pub fn compilerInsightsValue(allocator: std.mem.Allocator, stdout: []const u8, stderr: []const u8, argv: []const []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var findings = std.json.Array.init(allocator);
    var error_count: i64 = 0;
    var warning_count: i64 = 0;
    var note_count: i64 = 0;
    var primary: ?compiler_output.CompilerLine = null;
    try collectCompilerLines(allocator, &findings, stderr, &primary, &error_count, &warning_count, &note_count);
    try collectCompilerLines(allocator, &findings, stdout, &primary, &error_count, &warning_count, &note_count);
    var obj = std.json.ObjectMap.empty;
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

/// Collects compiler lines data into caller-provided output storage without taking ownership of inputs.
pub fn collectCompilerLines(allocator: std.mem.Allocator, findings: *std.json.Array, text_value: []const u8, primary: *?compiler_output.CompilerLine, error_count: *i64, warning_count: *i64, note_count: *i64) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

/// Serializes compiler line fields into an allocator-owned JSON value; allocation failures propagate.
pub fn compilerLineValue(allocator: std.mem.Allocator, parsed: compiler_output.CompilerLine) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "severity", .{ .string = parsed.severity });
    try obj.put(allocator, "message", try ownedString(allocator, parsed.message));
    try obj.put(allocator, "raw", try ownedString(allocator, parsed.raw));
    try obj.put(allocator, "path", if (parsed.path) |path| try ownedString(allocator, path) else .null);
    try obj.put(allocator, "line", if (parsed.line) |line_no| .{ .integer = line_no } else .null);
    try obj.put(allocator, "column", if (parsed.column) |col_no| .{ .integer = col_no } else .null);
    return .{ .object = obj };
}

/// Implements compiler next command workflow logic using caller-owned inputs.
pub fn compilerNextCommand(allocator: std.mem.Allocator, primary: compiler_output.CompilerLine, argv: []const []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const zig = if (argv.len > 0) argv[0] else "zig";
    const path = primary.path orelse return .{ .string = try commandString(allocator, argv) };
    if (path.len > 0 and std.mem.endsWith(u8, path, ".zig")) {
        if (argvContains(argv, "test")) return .{ .string = try std.fmt.allocPrint(allocator, "{s} test {s}", .{ zig, path }) };
        return .{ .string = try std.fmt.allocPrint(allocator, "{s} ast-check {s}", .{ zig, path }) };
    }
    return .{ .string = try commandString(allocator, argv) };
}

/// Implements compiler next actions workflow logic using caller-owned inputs.
pub fn compilerNextActions(allocator: std.mem.Allocator, primary: compiler_output.CompilerLine, note_count: i64) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
    if (note_count > 0) try actions.append(try ownedString(allocator, "Review compiler note entries before editing; Zig often puts the fix-relevant type or declaration context there."));
    if (std.mem.eql(u8, compiler_output.classifyDiagnosticMessage(primary.message), "missing_file_or_import")) {
        try actions.append(try ownedString(allocator, "Run zig_import_resolve for the failing @import name, then check build.zig addImport and build.zig.zon dependency wiring."));
    }
    try actions.append(try ownedString(allocator, "Rerun the next_command after the focused edit."));
    return .{ .array = actions };
}

/// Serializes failure summary fields into an allocator-owned JSON value; allocation failures propagate.
pub fn failureSummaryValue(allocator: std.mem.Allocator, insights: std.json.Value, ok: bool, argv: []const []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
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
        try suggested.append(try ownedString(allocator, "zigars_failure_fusion"));
        try suggested.append(try ownedString(allocator, "zigars_impact"));
    }
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", try likelyFailureScopeValue(allocator, primary));
    return .{ .object = obj };
}

/// Serializes command error summary fields into an allocator-owned JSON value; allocation failures propagate.
pub fn commandErrorSummaryValue(allocator: std.mem.Allocator, err: anyerror, argv: []const []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "primary", .null);
    try obj.put(allocator, "error_class", .{ .string = backendErrorKind(err) });
    try obj.put(allocator, "rerun_command", .{ .string = try commandString(allocator, argv) });
    var suggested = std.json.Array.init(allocator);
    try suggested.append(try ownedString(allocator, "zigars_doctor"));
    try suggested.append(try ownedString(allocator, "zigars_context_pack"));
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", .{ .string = if (err == error.Timeout or err == error.RequestTimeout) "command_timeout" else "tool_or_backend_configuration" });
    return .{ .object = obj };
}

/// Serializes likely failure scope fields into an allocator-owned JSON value; allocation failures propagate.
pub fn likelyFailureScopeValue(allocator: std.mem.Allocator, primary: std.json.Value) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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

pub const SafeText = struct {
    text: []const u8,
    invalid_utf8: bool,
    encoding: []const u8,
    byte_count: usize,
};

/// Copies command output into an allocator-owned buffer that is always valid
/// UTF-8: invalid byte sequences are replaced with U+FFFD so the result can be
/// embedded in MCP JSON. `byte_count` is the original length and `invalid_utf8`
/// records whether replacement happened.
pub fn safeTextAlloc(allocator: std.mem.Allocator, bytes: []const u8) !SafeText {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (std.unicode.utf8ValidateSlice(bytes)) {
        return .{ .text = try allocator.dupe(u8, bytes), .invalid_utf8 = false, .encoding = "utf-8", .byte_count = bytes.len };
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
    return .{ .text = try out.toOwnedSlice(allocator), .invalid_utf8 = true, .encoding = "utf-8-lossy", .byte_count = bytes.len };
}

/// Implements put stream fields workflow logic using caller-owned inputs.
pub fn putStreamFields(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, name: []const u8, safe: SafeText) !void {
    try obj.put(allocator, name, .{ .string = safe.text });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_invalid_utf8", .{name}), .{ .bool = safe.invalid_utf8 });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_encoding", .{name}), .{ .string = safe.encoding });
    try obj.put(allocator, try std.fmt.allocPrint(allocator, "{s}_byte_count", .{name}), .{ .integer = @intCast(safe.byte_count) });
}

/// Serializes finding fields into an allocator-owned JSON value; allocation failures propagate.
pub fn findingValue(allocator: std.mem.Allocator, source: []const u8, rule: []const u8, severity: []const u8, file: []const u8, line: usize, column: usize, message: []const u8, confidence: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "source", .{ .string = source });
    try obj.put(allocator, "rule", try ownedString(allocator, rule));
    try obj.put(allocator, "severity", try ownedString(allocator, severity));
    try obj.put(allocator, "location", try locationValue(allocator, file, line, column));
    try obj.put(allocator, "message", try ownedString(allocator, message));
    try obj.put(allocator, "confidence", .{ .string = confidence });
    try obj.put(allocator, "recommended_cross_check", try stringArrayValue(allocator, &.{ "zig_lint_compare", "zig build test" }));
    return .{ .object = obj };
}

/// Serializes summary fields into an allocator-owned JSON value; allocation failures propagate.
pub fn summaryValue(allocator: std.mem.Allocator, findings: std.json.Array) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var errors: usize = 0;
    var warnings: usize = 0;
    var infos: usize = 0;
    for (findings.items) |finding| {
        const obj = switch (finding) {
            .object => |o| o,
            else => continue,
        };
        const severity = stringField(obj, "severity") orelse continue;
        if (std.ascii.eqlIgnoreCase(severity, "error")) errors += 1 else if (std.ascii.eqlIgnoreCase(severity, "warning") or std.ascii.eqlIgnoreCase(severity, "warn")) warnings += 1 else infos += 1;
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "finding_count", .{ .integer = @intCast(findings.items.len) });
    try obj.put(allocator, "error_count", .{ .integer = @intCast(errors) });
    try obj.put(allocator, "warning_count", .{ .integer = @intCast(warnings) });
    try obj.put(allocator, "info_count", .{ .integer = @intCast(infos) });
    return .{ .object = obj };
}

/// Serializes location fields into an allocator-owned JSON value; allocation failures propagate.
pub fn locationValue(allocator: std.mem.Allocator, file: []const u8, line: usize, column: usize) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "line", .{ .integer = @intCast(@max(line, 1)) });
    try obj.put(allocator, "column", .{ .integer = @intCast(@max(column, 1)) });
    return .{ .object = obj };
}

/// Serializes fingerprint fields into an allocator-owned JSON value; allocation failures propagate.
pub fn fingerprintValue(allocator: std.mem.Allocator, finding: std.json.Value) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const obj = switch (finding) {
        .object => |o| o,
        else => return ownedString(allocator, "unknown"),
    };
    const source = stringField(obj, "source") orelse "unknown";
    const rule = stringField(obj, "rule") orelse "unknown";
    const message = stringField(obj, "message") orelse "";
    const location = switch (obj.get("location") orelse .null) {
        .object => |o| o,
        else => std.json.ObjectMap.empty,
    };
    const file = stringField(location, "file") orelse "unknown";
    const line = integerField(location, "line") orelse 0;
    return .{ .string = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}:{d}:{s}", .{ source, rule, file, line, message }) };
}

/// Implements comparison key workflow logic using caller-owned inputs.
pub fn comparisonKey(value: std.json.Value) []const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return "",
    };
    return stringField(obj, "comparison_key") orelse "";
}

/// Implements severity of workflow logic using caller-owned inputs.
pub fn severityOf(value: std.json.Value) []const u8 {
    const obj = switch (value) {
        .object => |o| o,
        else => return "",
    };
    return stringField(obj, "severity") orelse "";
}

/// Finds by comparison key data in the provided collection without taking ownership.
pub fn findByComparisonKey(array: std.json.Array, key: []const u8) ?std.json.Value {
    for (array.items) |item| if (std.mem.eql(u8, comparisonKey(item), key)) return item;
    return null;
}

/// Extracts string field data from JSON input without taking ownership of borrowed values.
pub fn stringField(obj: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    return switch (obj.get(field) orelse .null) {
        .string => |s| s,
        else => null,
    };
}

/// Extracts integer field data from JSON input without taking ownership of borrowed values.
pub fn integerField(obj: std.json.ObjectMap, field: []const u8) ?i64 {
    return switch (obj.get(field) orelse .null) {
        .integer => |i| i,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// Copies the provided string into allocator-owned storage.
pub fn ownedString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

/// Serializes string array fields into an allocator-owned JSON value; allocation failures propagate.
pub fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(try ownedString(allocator, value));
    return .{ .array = array };
}

/// Serializes argv fields into an allocator-owned JSON value; allocation failures propagate.
pub fn argvValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (argv) |arg| try array.append(try ownedString(allocator, arg));
    return .{ .array = array };
}

/// Formats argv entries into display command text.
pub fn commandString(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (argv.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

/// Reads the argv contains argument from JSON input without taking ownership of borrowed strings.
pub fn argvContains(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |arg| if (std.mem.eql(u8, arg, needle)) return true;
    return false;
}

/// Serializes alloc data into allocator-owned JSON text.
pub fn serializeAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    try serializeValue(allocator, &bytes, value);
    return bytes.toOwnedSlice(allocator);
}

/// Serializes serialize fields into an allocator-owned JSON value; allocation failures propagate.
pub fn serializeValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: std.json.Value) !void {
    // Keep serialization centralized so output formatting stays consistent across call sites.
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| try out.print(allocator, "{d}", .{i}),
        .float => |f| try out.print(allocator, "{d}", .{f}),
        .number_string => |s| try out.appendSlice(allocator, s),
        .string => |s| try serializeString(allocator, out, s),
        .array => |array| {
            try out.append(allocator, '[');
            for (array.items, 0..) |item, index| {
                if (index > 0) try out.append(allocator, ',');
                try serializeValue(allocator, out, item);
            }
            try out.append(allocator, ']');
        },
        .object => |object| {
            try out.append(allocator, '{');
            var it = object.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try out.append(allocator, ',');
                first = false;
                try serializeString(allocator, out, entry.key_ptr.*);
                try out.append(allocator, ':');
                try serializeValue(allocator, out, entry.value_ptr.*);
            }
            try out.append(allocator, '}');
        },
    }
}

/// Serializes string data into allocator-owned JSON text.
pub fn serializeString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    // Keep serialization centralized so output formatting stays consistent across call sites.
    const hex = "0123456789abcdef";
    try out.append(allocator, '"');
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        0...8, 11...12, 14...0x1f => {
            try out.appendSlice(allocator, "\\u00");
            try out.append(allocator, hex[c >> 4]);
            try out.append(allocator, hex[c & 0x0f]);
        },
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '"');
}
