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
const commandErrorValue = common.commandErrorValue;
const compilerInsightsValue = common.compilerInsightsValue;
const failureSummaryValue = common.failureSummaryValue;
const commandErrorSummaryValue = common.commandErrorSummaryValue;
const commandRunErrorResult = common.commandRunErrorResult;
const splitToolArgs = common.splitToolArgs;
const splitToolArgsErrorResult = common.splitToolArgsErrorResult;
const freeArgList = common.freeArgList;
const parseCompilerLine = common.parseCompilerLine;
const classifyDiagnosticMessage = common.classifyDiagnosticMessage;
const commandString = common.commandString;
const argvValue = common.argvValue;

const ci_annotations_basis = "Zig compiler diagnostics parsed from stderr lines shaped as path:line:column: severity: message plus unlocated severity prefixes";
const ci_annotations_limitations = "Parses common Zig compiler diagnostic lines and attaches following source/caret lines as details; raw stderr remains the audit source.";
const junit_artifact_kind = "command_level_junit";
const junit_basis = "Zig command exit status with stdout/stderr preserved; no per-test event stream is inferred.";
const junit_limitations = "JUnit contains one command-level testcase because Zig output does not expose stable per-test records for every invocation.";
const matrix_basis = "Each matrix entry is the direct process result for one provided Zig executable path.";
const matrix_limitations = "Matrix checks execute only the supplied Zig paths and arguments; platform matrix discovery remains a CI concern.";

pub const AnnotationParseSummary = struct {
    input_lines: i64 = 0,
    annotation_count: i64 = 0,
    located_diagnostics: i64 = 0,
    unlocated_diagnostics: i64 = 0,
    detail_lines: i64 = 0,

    pub fn confidence(self: AnnotationParseSummary) []const u8 {
        if (self.annotation_count == 0) return "low";
        if (self.located_diagnostics == self.annotation_count) return "high";
        if (self.located_diagnostics > 0) return "medium";
        return "low";
    }
};

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
    const parse_summary = tryParseAnnotations(allocator, &annotations, file, result.stderr) catch return error.OutOfMemory;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "kind", .{ .string = "zig_ci_annotations" }) catch return error.OutOfMemory;
    obj.put(allocator, "ok", .{ .bool = result.succeeded() }) catch return error.OutOfMemory;
    obj.put(allocator, "artifact_kind", .{ .string = "ci_annotations" }) catch return error.OutOfMemory;
    obj.put(allocator, "parsing_basis", .{ .string = ci_annotations_basis }) catch return error.OutOfMemory;
    obj.put(allocator, "parser_confidence", .{ .string = parse_summary.confidence() }) catch return error.OutOfMemory;
    obj.put(allocator, "limitations", .{ .string = ci_annotations_limitations }) catch return error.OutOfMemory;
    obj.put(allocator, "raw_output_available", .{ .bool = true }) catch return error.OutOfMemory;
    obj.put(allocator, "annotation_count", .{ .integer = parse_summary.annotation_count }) catch return error.OutOfMemory;
    obj.put(allocator, "parse_summary", annotationParseSummaryValue(allocator, parse_summary) catch return error.OutOfMemory) catch return error.OutOfMemory;
    obj.put(allocator, "annotations", .{ .array = annotations }) catch return error.OutOfMemory;
    obj.put(allocator, "raw", commandResultValue(allocator, "zig ast-check", argv, a.workspace.root, timeout_ms, result) catch return error.OutOfMemory) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn tryParseAnnotations(allocator: std.mem.Allocator, annotations: *std.json.Array, default_file: []const u8, stderr: []const u8) !AnnotationParseSummary {
    var summary: AnnotationParseSummary = .{};
    var last_annotation: ?usize = null;
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;
        summary.input_lines += 1;
        if (parseCompilerLine(line)) |parsed| {
            try annotations.append(try annotationValue(allocator, default_file, parsed));
            last_annotation = annotations.items.len - 1;
            summary.annotation_count += 1;
            if (parsed.path != null and parsed.line != null and parsed.column != null) {
                summary.located_diagnostics += 1;
            } else {
                summary.unlocated_diagnostics += 1;
            }
        } else if (last_annotation) |idx| {
            try appendAnnotationDetail(allocator, &annotations.items[idx], line);
            summary.detail_lines += 1;
        }
    }
    return summary;
}

fn annotationValue(allocator: std.mem.Allocator, default_file: []const u8, parsed: common.CompilerLine) !std.json.Value {
    const located = parsed.path != null and parsed.line != null and parsed.column != null;
    const details = std.json.Array.init(allocator);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = parsed.path orelse default_file });
    try obj.put(allocator, "start_line", .{ .integer = parsed.line orelse 1 });
    try obj.put(allocator, "start_column", .{ .integer = parsed.column orelse 1 });
    try obj.put(allocator, "end_line", .{ .integer = parsed.line orelse 1 });
    try obj.put(allocator, "annotation_level", .{ .string = annotationLevel(parsed.severity) });
    try obj.put(allocator, "severity", .{ .string = parsed.severity });
    try obj.put(allocator, "diagnostic_class", .{ .string = classifyDiagnosticMessage(parsed.message) });
    try obj.put(allocator, "message", .{ .string = parsed.message });
    try obj.put(allocator, "raw", .{ .string = parsed.raw });
    try obj.put(allocator, "parser_confidence", .{ .string = if (located) "high" else "low" });
    try obj.put(allocator, "parsing_basis", .{ .string = if (located) "located Zig compiler diagnostic" else "unlocated Zig compiler diagnostic" });
    try obj.put(allocator, "details", .{ .array = details });
    return .{ .object = obj };
}

fn appendAnnotationDetail(allocator: std.mem.Allocator, annotation: *std.json.Value, detail: []const u8) !void {
    switch (annotation.*) {
        .object => |*obj| {
            const details_value = obj.getPtr("details") orelse return;
            switch (details_value.*) {
                .array => |*details| try details.append(try common.ownedString(allocator, detail)),
                else => {},
            }
        },
        else => {},
    }
}

fn annotationLevel(severity: []const u8) []const u8 {
    if (std.mem.eql(u8, severity, "warning")) return "warning";
    if (std.mem.eql(u8, severity, "note")) return "notice";
    return "failure";
}

fn annotationParseSummaryValue(allocator: std.mem.Allocator, summary: AnnotationParseSummary) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "input_lines", .{ .integer = summary.input_lines });
    try obj.put(allocator, "annotation_count", .{ .integer = summary.annotation_count });
    try obj.put(allocator, "located_diagnostics", .{ .integer = summary.located_diagnostics });
    try obj.put(allocator, "unlocated_diagnostics", .{ .integer = summary.unlocated_diagnostics });
    try obj.put(allocator, "detail_lines", .{ .integer = summary.detail_lines });
    try obj.put(allocator, "parser_confidence", .{ .string = summary.confidence() });
    return .{ .object = obj };
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
            else => if (isXmlChar(c)) try out.append(allocator, c) else try out.appendSlice(allocator, "&#xFFFD;"),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn isXmlChar(c: u8) bool {
    return c == 0x09 or c == 0x0a or c == 0x0d or c >= 0x20;
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
    const xml = junitXmlForCommand(allocator, list.items, result) catch return error.OutOfMemory;
    defer allocator.free(xml);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "kind", .{ .string = "zig_junit" }) catch return error.OutOfMemory;
    obj.put(allocator, "ok", .{ .bool = result.succeeded() }) catch return error.OutOfMemory;
    obj.put(allocator, "artifact_kind", .{ .string = junit_artifact_kind }) catch return error.OutOfMemory;
    obj.put(allocator, "junit_kind", .{ .string = "command_level" }) catch return error.OutOfMemory;
    obj.put(allocator, "tests", .{ .integer = 1 }) catch return error.OutOfMemory;
    obj.put(allocator, "failures", .{ .integer = if (result.succeeded()) 0 else 1 }) catch return error.OutOfMemory;
    obj.put(allocator, "parsing_basis", .{ .string = junit_basis }) catch return error.OutOfMemory;
    obj.put(allocator, "limitations", .{ .string = junit_limitations }) catch return error.OutOfMemory;
    obj.put(allocator, "raw_output_available", .{ .bool = true }) catch return error.OutOfMemory;
    obj.put(allocator, "junit_xml", .{ .string = xml }) catch return error.OutOfMemory;
    obj.put(allocator, "command", commandResultValue(allocator, "zig test", list.items, a.workspace.root, timeout_ms, result) catch return error.OutOfMemory) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn junitXmlForCommand(allocator: std.mem.Allocator, argv: []const []const u8, result: command.RunResult) ![]u8 {
    const command_text = try commandString(allocator, argv);
    defer allocator.free(command_text);
    const command_xml = try xmlEscape(allocator, command_text);
    defer allocator.free(command_xml);
    const basis_xml = try xmlEscape(allocator, junit_basis);
    defer allocator.free(basis_xml);
    const limitations_xml = try xmlEscape(allocator, junit_limitations);
    defer allocator.free(limitations_xml);
    const stdout_xml = try xmlEscape(allocator, result.stdout);
    defer allocator.free(stdout_xml);
    const stderr_xml = try xmlEscape(allocator, result.stderr);
    defer allocator.free(stderr_xml);
    const failure_body = if (result.stderr.len > 0) result.stderr else result.stdout;
    const failure_body_xml = try xmlEscape(allocator, failure_body);
    defer allocator.free(failure_body_xml);
    const failure_xml = if (result.succeeded())
        try allocator.dupe(u8, "")
    else
        try std.fmt.allocPrint(allocator, "<failure message=\"zig command failed\" type=\"command_failure\">{s}</failure>", .{failure_body_xml});
    defer allocator.free(failure_xml);
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<testsuite name="zigar.zig_junit" tests="1" failures="{d}" errors="0" skipped="0">
        \\  <properties>
        \\    <property name="zigar.artifact_kind" value="{s}"/>
        \\    <property name="zigar.command" value="{s}"/>
        \\    <property name="zigar.parsing_basis" value="{s}"/>
        \\    <property name="zigar.limitations" value="{s}"/>
        \\  </properties>
        \\  <testcase classname="zigar.command" name="{s}">
        \\    {s}
        \\  </testcase>
        \\  <system-out>{s}</system-out>
        \\  <system-err>{s}</system-err>
        \\</testsuite>
        \\
    , .{ if (result.succeeded()) @as(i32, 0) else @as(i32, 1), junit_artifact_kind, command_xml, basis_xml, limitations_xml, command_xml, failure_xml, stdout_xml, stderr_xml });
}

pub fn zigMatrixCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const paths_text = argString(args, "zig_paths") orelse a.config.zig_path;
    var paths = std.mem.tokenizeAny(u8, paths_text, ", \t\r\n");
    var results = std.json.Array.init(allocator);
    var ok = true;
    var passed: i64 = 0;
    var failed: i64 = 0;
    const timeout_ms = toolTimeout(a, args);
    while (paths.next()) |zig_path| {
        const raw_extra_args = argString(args, "args") orelse "";
        const extra = splitToolArgs(allocator, raw_extra_args) catch |err| return splitToolArgsErrorResult(allocator, "zig_matrix_check", "args", raw_extra_args, err);
        defer freeArgList(allocator, extra);
        const argv = command.joinArgv(allocator, &.{ zig_path, "build", "test" }, extra) catch return error.OutOfMemory;
        defer allocator.free(argv);
        a.command_calls += 1;
        const run = command.run(allocator, a.io, a.workspace.root, argv, timeout_ms) catch |err| {
            ok = false;
            failed += 1;
            results.append(matrixCommandErrorEntryValue(allocator, zig_path, argv, a.workspace.root, timeout_ms, err) catch return error.OutOfMemory) catch return error.OutOfMemory;
            continue;
        };
        defer run.deinit(allocator);
        if (run.succeeded()) {
            passed += 1;
        } else {
            ok = false;
            failed += 1;
        }
        results.append(matrixRunEntryValue(allocator, zig_path, argv, a.workspace.root, timeout_ms, run) catch return error.OutOfMemory) catch return error.OutOfMemory;
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    obj.put(allocator, "kind", .{ .string = "zig_matrix_check" }) catch return error.OutOfMemory;
    obj.put(allocator, "ok", .{ .bool = ok }) catch return error.OutOfMemory;
    obj.put(allocator, "artifact_kind", .{ .string = "zig_matrix_results" }) catch return error.OutOfMemory;
    obj.put(allocator, "entry_count", .{ .integer = passed + failed }) catch return error.OutOfMemory;
    obj.put(allocator, "passed", .{ .integer = passed }) catch return error.OutOfMemory;
    obj.put(allocator, "failed", .{ .integer = failed }) catch return error.OutOfMemory;
    obj.put(allocator, "parsing_basis", .{ .string = matrix_basis }) catch return error.OutOfMemory;
    obj.put(allocator, "limitations", .{ .string = matrix_limitations }) catch return error.OutOfMemory;
    obj.put(allocator, "raw_output_available", .{ .bool = true }) catch return error.OutOfMemory;
    obj.put(allocator, "results", .{ .array = results }) catch return error.OutOfMemory;
    return structured(allocator, .{ .object = obj });
}

pub fn matrixRunEntryValue(allocator: std.mem.Allocator, zig_path: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, result: command.RunResult) !std.json.Value {
    const insights = try compilerInsightsValue(allocator, result.stdout, result.stderr, argv);
    var item = std.json.ObjectMap.empty;
    errdefer item.deinit(allocator);
    try item.put(allocator, "kind", .{ .string = "zig_matrix_entry" });
    try item.put(allocator, "zig", .{ .string = zig_path });
    try item.put(allocator, "ok", .{ .bool = result.succeeded() });
    try item.put(allocator, "command", .{ .string = try commandString(allocator, argv) });
    try item.put(allocator, "argv", try argvValue(allocator, argv));
    try item.put(allocator, "failure_summary", try failureSummaryValue(allocator, insights, result.succeeded(), argv));
    try item.put(allocator, "result", try commandResultValue(allocator, "zig build test", argv, cwd, timeout_ms, result));
    return .{ .object = item };
}

pub fn matrixCommandErrorEntryValue(allocator: std.mem.Allocator, zig_path: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, err: anyerror) !std.json.Value {
    var item = std.json.ObjectMap.empty;
    errdefer item.deinit(allocator);
    try item.put(allocator, "kind", .{ .string = "zig_matrix_entry" });
    try item.put(allocator, "zig", .{ .string = zig_path });
    try item.put(allocator, "ok", .{ .bool = false });
    try item.put(allocator, "command", .{ .string = try commandString(allocator, argv) });
    try item.put(allocator, "argv", try argvValue(allocator, argv));
    try item.put(allocator, "error", .{ .string = @errorName(err) });
    try item.put(allocator, "error_kind", .{ .string = command.errorKind(err) });
    try item.put(allocator, "failure_summary", try commandErrorSummaryValue(allocator, err, argv));
    try item.put(allocator, "result", try commandErrorValue(allocator, "zig build test", argv, cwd, timeout_ms, err));
    return .{ .object = item };
}
