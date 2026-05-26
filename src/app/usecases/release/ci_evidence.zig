const std = @import("std");
const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const support = @import("../usecase_support.zig");

const command = support.command;

pub const App = support.UsecaseApp(app_context.ReleaseWorkflowContext);
pub const Result = support.Result;
const structured = support.structured;
const argString = support.argString;
const missingArgumentResult = support.missingArgumentResult;
const workspacePathErrorResult = support.workspacePathErrorResult;
const toolTimeout = support.toolTimeout;
const commandResultValue = support.commandResultValue;
const commandErrorValue = support.commandErrorValue;
const compilerInsightsValue = support.compilerInsightsValue;
const failureSummaryValue = support.failureSummaryValue;
const commandErrorSummaryValue = support.commandErrorSummaryValue;
const commandRunErrorResult = support.commandRunErrorResult;
const splitToolArgs = support.splitToolArgs;
const splitToolArgsErrorResult = support.splitToolArgsErrorResult;
const freeArgList = support.freeArgList;
const parseCompilerLine = support.parseCompilerLine;
const classifyDiagnosticMessage = support.classifyDiagnosticMessage;
const commandString = support.commandString;
const argvValue = support.argvValue;

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

pub fn zigCiAnnotations(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const file = argString(args, "file") orelse return missingArgumentResult(allocator, "zig_ci_annotations", "file", "workspace-relative Zig source path");
    const resolved = a.workspace.resolve(file) catch |err| return workspacePathErrorResult(a, allocator, "zig_ci_annotations", file, err);
    defer allocator.free(resolved);
    a.command_calls += 1;
    const timeout_ms = toolTimeout(a, args);
    const argv = &.{ a.config.zig_path, "ast-check", resolved };
    const result = support.runCommand(allocator, a, argv, timeout_ms) catch |err| return commandRunErrorResult(allocator, .{
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
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
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
    obj_owned = false;
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

fn annotationValue(allocator: std.mem.Allocator, default_file: []const u8, parsed: support.CompilerLine) !std.json.Value {
    const located = parsed.path != null and parsed.line != null and parsed.column != null;
    const start_column = parsed.column orelse 1;
    const end_column = if (start_column == std.math.maxInt(i64)) start_column else start_column + 1;
    const details = std.json.Array.init(allocator);
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "path", .{ .string = parsed.path orelse default_file });
    try obj.put(allocator, "start_line", .{ .integer = parsed.line orelse 1 });
    try obj.put(allocator, "start_column", .{ .integer = start_column });
    try obj.put(allocator, "end_line", .{ .integer = parsed.line orelse 1 });
    try obj.put(allocator, "end_column", .{ .integer = end_column });
    try obj.put(allocator, "located", .{ .bool = located });
    try obj.put(allocator, "annotation_level", .{ .string = annotationLevel(parsed.severity) });
    try obj.put(allocator, "severity", .{ .string = parsed.severity });
    try obj.put(allocator, "diagnostic_class", .{ .string = classifyDiagnosticMessage(parsed.message) });
    try obj.put(allocator, "message", .{ .string = parsed.message });
    try obj.put(allocator, "raw", .{ .string = parsed.raw });
    try obj.put(allocator, "parser_confidence", .{ .string = if (located) "high" else "low" });
    try obj.put(allocator, "parsing_basis", .{ .string = if (located) "located Zig compiler diagnostic" else "unlocated Zig compiler diagnostic" });
    try obj.put(allocator, "details", .{ .array = details });
    obj_owned = false;
    return .{ .object = obj };
}

fn appendAnnotationDetail(allocator: std.mem.Allocator, annotation: *std.json.Value, detail: []const u8) !void {
    switch (annotation.*) {
        .object => |*obj| {
            const details_value = obj.getPtr("details") orelse return;
            switch (details_value.*) {
                .array => |*details| try details.append(try support.ownedString(allocator, detail)),
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
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "input_lines", .{ .integer = summary.input_lines });
    try obj.put(allocator, "annotation_count", .{ .integer = summary.annotation_count });
    try obj.put(allocator, "located_diagnostics", .{ .integer = summary.located_diagnostics });
    try obj.put(allocator, "unlocated_diagnostics", .{ .integer = summary.unlocated_diagnostics });
    try obj.put(allocator, "detail_lines", .{ .integer = summary.detail_lines });
    try obj.put(allocator, "parser_confidence", .{ .string = summary.confidence() });
    obj_owned = false;
    return .{ .object = obj };
}

pub fn xmlEscape(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var out_owned = true;
    defer if (out_owned) out.deinit(allocator);
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
    const bytes = try out.toOwnedSlice(allocator);
    out_owned = false;
    return bytes;
}

fn isXmlChar(c: u8) bool {
    return c == 0x09 or c == 0x0a or c == 0x0d or c >= 0x20;
}

pub fn zigJunit(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
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
    const result = support.runCommand(allocator, a, list.items, timeout_ms) catch |err| return commandRunErrorResult(allocator, .{
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
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
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
    obj_owned = false;
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
        \\    <property name="zigar.junit_kind" value="command_level"/>
        \\    <property name="zigar.raw_output_available" value="true"/>
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

pub fn zigMatrixCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
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
        const run = support.runCommand(allocator, a, argv, timeout_ms) catch |err| {
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
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
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
    obj_owned = false;
    return structured(allocator, .{ .object = obj });
}

pub fn matrixRunEntryValue(allocator: std.mem.Allocator, zig_path: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, result: command.RunResult) !std.json.Value {
    const insights = try compilerInsightsValue(allocator, result.stdout, result.stderr, argv);
    var item = std.json.ObjectMap.empty;
    var item_owned = true;
    defer if (item_owned) item.deinit(allocator);
    try item.put(allocator, "kind", .{ .string = "zig_matrix_entry" });
    try item.put(allocator, "zig", .{ .string = zig_path });
    try item.put(allocator, "ok", .{ .bool = result.succeeded() });
    try item.put(allocator, "command", .{ .string = try commandString(allocator, argv) });
    try item.put(allocator, "argv", try argvValue(allocator, argv));
    try item.put(allocator, "failure_summary", try failureSummaryValue(allocator, insights, result.succeeded(), argv));
    try item.put(allocator, "result", try commandResultValue(allocator, "zig build test", argv, cwd, timeout_ms, result));
    item_owned = false;
    return .{ .object = item };
}

pub fn matrixCommandErrorEntryValue(allocator: std.mem.Allocator, zig_path: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, err: anyerror) !std.json.Value {
    var item = std.json.ObjectMap.empty;
    var item_owned = true;
    defer if (item_owned) item.deinit(allocator);
    try item.put(allocator, "kind", .{ .string = "zig_matrix_entry" });
    try item.put(allocator, "zig", .{ .string = zig_path });
    try item.put(allocator, "ok", .{ .bool = false });
    try item.put(allocator, "command", .{ .string = try commandString(allocator, argv) });
    try item.put(allocator, "argv", try argvValue(allocator, argv));
    try item.put(allocator, "error", .{ .string = @errorName(err) });
    try item.put(allocator, "error_kind", .{ .string = command.errorKind(err) });
    try item.put(allocator, "failure_summary", try commandErrorSummaryValue(allocator, err, argv));
    try item.put(allocator, "result", try commandErrorValue(allocator, "zig build test", argv, cwd, timeout_ms, err));
    item_owned = false;
    return .{ .object = item };
}

const fakes = @import("../../../testing/fakes/root.zig");

test "CI annotation parsing captures located unlocated and detail lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var annotations = std.json.Array.init(allocator);
    const summary = try tryParseAnnotations(allocator, &annotations, "src/default.zig",
        \\src/main.zig:2:3: warning: unused local constant
        \\    const x = 1;
        \\    ^~~~~
        \\error: build failed
        \\note: rerun with --summary all
        \\
    );
    try std.testing.expectEqual(@as(i64, 5), summary.input_lines);
    try std.testing.expectEqual(@as(i64, 3), summary.annotation_count);
    try std.testing.expectEqual(@as(i64, 1), summary.located_diagnostics);
    try std.testing.expectEqual(@as(i64, 2), summary.unlocated_diagnostics);
    try std.testing.expectEqual(@as(i64, 2), summary.detail_lines);
    try std.testing.expectEqualStrings("medium", summary.confidence());

    const first = annotations.items[0].object;
    try std.testing.expectEqualStrings("src/main.zig", first.get("path").?.string);
    try std.testing.expectEqualStrings("warning", first.get("annotation_level").?.string);
    try std.testing.expectEqual(@as(usize, 2), first.get("details").?.array.items.len);
    const summary_value = (try annotationParseSummaryValue(allocator, summary)).object;
    try std.testing.expectEqualStrings("medium", summary_value.get("parser_confidence").?.string);

    try std.testing.expectEqualStrings("low", (AnnotationParseSummary{}).confidence());
    try std.testing.expectEqualStrings("high", (AnnotationParseSummary{ .annotation_count = 1, .located_diagnostics = 1 }).confidence());
    try std.testing.expectEqualStrings("low", (AnnotationParseSummary{ .annotation_count = 1, .unlocated_diagnostics = 1 }).confidence());
    try std.testing.expectEqualStrings("notice", annotationLevel("note"));
    try std.testing.expectEqualStrings("failure", annotationLevel("error"));
}

test "CI XML and matrix projections escape command output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const escaped = try xmlEscape(allocator, "&<>\"'\x01ok");
    try std.testing.expectEqualStrings("&amp;&lt;&gt;&quot;&apos;&#xFFFD;ok", escaped);

    const argv = &.{ "zig", "test", "src/main.zig" };
    const failed = command.RunResult{
        .term = .{ .exited = 1 },
        .stdout = "out <ok>",
        .stderr = "src/main.zig:1:1: error: bad & worse",
        .duration_ms = 17,
    };
    const failed_xml = try junitXmlForCommand(allocator, argv, failed);
    try std.testing.expect(std.mem.indexOf(u8, failed_xml, "<failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_xml, "&amp; worse") != null);

    const passed = command.RunResult{
        .term = .{ .exited = 0 },
        .stdout = "ok",
        .stderr = "",
        .duration_ms = 3,
    };
    const passed_xml = try junitXmlForCommand(allocator, argv, passed);
    try std.testing.expect(std.mem.indexOf(u8, passed_xml, "failures=\"0\"") != null);

    const run_entry = (try matrixRunEntryValue(allocator, "zig", argv, "/repo", 1000, failed)).object;
    try std.testing.expectEqualStrings("zig_matrix_entry", run_entry.get("kind").?.string);
    try std.testing.expect(!run_entry.get("ok").?.bool);

    const error_entry = (try matrixCommandErrorEntryValue(allocator, "zig-nightly", argv, "/repo", 1000, error.Timeout)).object;
    try std.testing.expectEqualStrings("Timeout", error_entry.get("error").?.string);
    try std.testing.expect(error_entry.get("result") != null);
}

test "CI public workflows run annotations junit and matrix through ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();
    var workspace_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace_fake.deinit();

    try workspace_fake.expectResolve(.{ .path = "src/main.zig", .provenance = "arch110-workflow-resolve" }, "/repo/src/main.zig");
    try command_fake.expectRun(.{
        .argv = &.{ "zig", "ast-check", "/repo/src/main.zig" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 1,
        .stderr = "src/main.zig:1:1: error: bad\n    ^\n",
        .duration_ms = 8,
    });

    try workspace_fake.expectResolve(.{ .path = "tests/main_test.zig", .provenance = "arch110-workflow-resolve" }, "/repo/tests/main_test.zig");
    try command_fake.expectRun(.{
        .argv = &.{ "zig", "test", "/repo/tests/main_test.zig", "--test-filter", "case", "--summary", "all" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 1,
        .stdout = "FAIL case\n",
        .stderr = "tests/main_test.zig:2:1: error: failed\n",
        .duration_ms = 11,
    });

    try command_fake.expectRun(.{
        .argv = &.{ "zig", "build", "test" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 0,
        .stdout = "ok\n",
        .duration_ms = 5,
    });

    try command_fake.expectRun(.{
        .argv = &.{ "zig-a", "build", "test", "--summary", "all" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 0,
        .stdout = "ok\n",
        .duration_ms = 6,
    });
    try command_fake.expectRun(.{
        .argv = &.{ "zig-b", "build", "test", "--summary", "all" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 1,
        .stderr = "src/main.zig:3:1: error: nightly failure\n",
        .duration_ms = 7,
    });
    try command_fake.expectRunError(.{
        .argv = &.{ "zig-c", "build", "test", "--summary", "all" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, error.Timeout);

    var app = App.init(releaseWorkflowTestContext(command_fake.port(), workspace_fake.port()), allocator);

    const annotations_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"src/main.zig\"}", .{});
    const annotations = try zigCiAnnotations(&app, allocator, annotations_args.value);
    try std.testing.expectEqualStrings("zig_ci_annotations", annotations.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), annotations.value.object.get("annotation_count").?.integer);

    const junit_file_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"tests/main_test.zig\",\"filter\":\"case\",\"args\":\"--summary all\"}", .{});
    const junit_file = try zigJunit(&app, allocator, junit_file_args.value);
    try std.testing.expect(!junit_file.value.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 1), junit_file.value.object.get("failures").?.integer);

    const junit_build = try zigJunit(&app, allocator, null);
    try std.testing.expect(junit_build.value.object.get("ok").?.bool);

    const matrix_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"zig_paths\":\"zig-a zig-b zig-c\",\"args\":\"--summary all\"}", .{});
    const matrix = try zigMatrixCheck(&app, allocator, matrix_args.value);
    try std.testing.expect(!matrix.value.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 1), matrix.value.object.get("passed").?.integer);
    try std.testing.expectEqual(@as(i64, 2), matrix.value.object.get("failed").?.integer);

    try command_fake.verify();
    try workspace_fake.verify();
}

test "CI workflows render command runner errors as structured results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();
    var workspace_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace_fake.deinit();

    try workspace_fake.expectResolve(.{ .path = "src/main.zig", .provenance = "arch110-workflow-resolve" }, "/repo/src/main.zig");
    try command_fake.expectRunError(.{
        .argv = &.{ "zig", "ast-check", "/repo/src/main.zig" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, error.Unavailable);
    try workspace_fake.expectResolve(.{ .path = "tests/main_test.zig", .provenance = "arch110-workflow-resolve" }, "/repo/tests/main_test.zig");
    try command_fake.expectRunError(.{
        .argv = &.{ "zig", "test", "/repo/tests/main_test.zig" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, error.Timeout);

    var app = App.init(releaseWorkflowTestContext(command_fake.port(), workspace_fake.port()), allocator);
    const annotations_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"src/main.zig\"}", .{});
    const annotations = try zigCiAnnotations(&app, allocator, annotations_args.value);
    try std.testing.expect(!annotations.is_error);
    try std.testing.expectEqualStrings("command_error", annotations.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("run_ast_check", annotations.value.object.get("title").?.string);
    try std.testing.expectEqualStrings("Unavailable", annotations.value.object.get("error").?.string);

    const junit_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"tests/main_test.zig\"}", .{});
    const junit = try zigJunit(&app, allocator, junit_args.value);
    try std.testing.expect(!junit.is_error);
    try std.testing.expectEqualStrings("command_error", junit.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("run_tests", junit.value.object.get("title").?.string);
    try std.testing.expectEqualStrings("Timeout", junit.value.object.get("error").?.string);

    try command_fake.verify();
    try workspace_fake.verify();
}

fn releaseWorkflowTestContext(command_runner: ports.CommandRunner, workspace_store: ports.WorkspaceStore) app_context.ReleaseWorkflowContext {
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache", .transport = "test" },
        .tool_paths = .{ .zig = "zig" },
        .timeouts = .{ .command_ms = 1000, .zls_ms = 1000 },
        .command_runner = command_runner,
        .workspace_store = workspace_store,
        .workspace_scanner = undefined,
        .tool_manifest = undefined,
    };
}
