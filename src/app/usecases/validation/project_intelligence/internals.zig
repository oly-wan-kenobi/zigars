//! Internal implementation helpers for the project-intelligence use cases:
//! validation/phase rendering, command argv building and execution shaping,
//! event parsing, impact collection, project memory, and capability matching.
//! Extracted from project_intelligence.zig so the orchestrator module stays
//! focused on the public use-case surface. This is a pure helper layer: it
//! never calls the public orchestrators, only shared types, the support leaf
//! helpers, domain modules, and effect ports.
const std = @import("std");
const app_context = @import("../../../context.zig");
const ports = @import("../../../ports.zig");
const zig_analysis = @import("../../../../domain/zig/analysis.zig");
const project_values = @import("../../static_analysis/project_values.zig");
const semantic_usecase = @import("../../static_analysis/semantic_index.zig");
const workflows = @import("../workflows.zig");
const types = @import("types.zig");
const support = @import("support.zig");

const PathList = types.PathList;
const ArgvList = types.ArgvList;
const FailureFusionRequest = types.FailureFusionRequest;
const CommandEventsRequest = types.CommandEventsRequest;
const CapabilityEntry = types.CapabilityEntry;
const ToolRisk = types.ToolRisk;
const EventCommandKind = types.EventCommandKind;
const schema_version = types.schema_version;
const semantic_limit_default = types.semantic_limit_default;
const memory_path_default = types.memory_path_default;
const profile_path_default = types.profile_path_default;

const SafeText = support.SafeText;
const argvOwnedValue = support.argvOwnedValue;
const commandTermValue = support.commandTermValue;
const safeTextAlloc = support.safeTextAlloc;
const putStreamFields = support.putStreamFields;
const commandErrorKind = support.commandErrorKind;
const backendErrorValue = support.backendErrorValue;
const isOutputLimitError = support.isOutputLimitError;
const isTimeoutError = support.isTimeoutError;
const stringListContains = support.stringListContains;
const freeStringList = support.freeStringList;
const jsonArrayLen = support.jsonArrayLen;
const boolField = support.boolField;
const stringField = support.stringField;
const integerField = support.integerField;
const ownedString = support.ownedString;
const stringArrayValue = support.stringArrayValue;
const cloneValue = support.cloneValue;
const serializeValue = support.serializeValue;
const jsonLineForRecord = support.jsonLineForRecord;
const sha256Hex = support.sha256Hex;
const importsTarget = support.importsTarget;
const referencesFileStem = support.referencesFileStem;
const looksLikeTestFile = support.looksLikeTestFile;

pub fn validationRiskValue(allocator: std.mem.Allocator, risk: workflows.Risk) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "changed_file_count", .{ .integer = @intCast(risk.changed_file_count) });
    try obj.put(allocator, "touches_zig_source", .{ .bool = risk.touches_zig_source });
    try obj.put(allocator, "touches_build_config", .{ .bool = risk.touches_build_config });
    try obj.put(allocator, "touches_docs", .{ .bool = risk.touches_docs });
    try obj.put(allocator, "level", try ownedString(allocator, risk.level));
    return .{ .object = obj };
}

/// Serializes validation phases fields into an allocator-owned JSON value; allocation failures propagate.
pub fn validationPhasesValue(allocator: std.mem.Allocator, phases: []const workflows.Phase) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (phases) |phase| try array.append(try validationPhaseValue(allocator, phase));
    return .{ .array = array };
}

/// Serializes validation phase fields into an allocator-owned JSON value; allocation failures propagate.
pub fn validationPhaseValue(allocator: std.mem.Allocator, phase: workflows.Phase) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "id", try ownedString(allocator, phase.id));
    try obj.put(allocator, "kind", try ownedString(allocator, phase.kind.name()));
    try obj.put(allocator, "tool", if (phase.tool) |tool| try ownedString(allocator, tool) else .null);
    try obj.put(allocator, "argv", if (phase.argv) |argv| try argvOwnedValue(allocator, argv.items) else .null);
    try obj.put(allocator, "reason", try ownedString(allocator, phase.reason));
    try obj.put(allocator, "required", .{ .bool = phase.required });
    try obj.put(allocator, "risk", try ownedString(allocator, phase.risk));
    return .{ .object = obj };
}

/// Serializes skipped phases fields into an allocator-owned JSON value; allocation failures propagate.
pub fn skippedPhasesValue(allocator: std.mem.Allocator, skipped: []const workflows.SkippedPhase) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var array = std.json.Array.init(allocator);
    for (skipped) |item| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "name", try ownedString(allocator, item.name));
        try obj.put(allocator, "reason", try ownedString(allocator, item.reason));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

/// Serializes validation phase run fields into an allocator-owned JSON value; allocation failures propagate.
pub fn validationPhaseRunValue(allocator: std.mem.Allocator, phase: workflows.PhaseRun) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "name", try ownedString(allocator, phase.name));
    try obj.put(allocator, "ok", .{ .bool = phase.ok });
    try obj.put(allocator, "command", try phaseCommandValue(allocator, phase));
    try obj.put(allocator, "events", try phaseEventsValue(allocator, phase));
    return .{ .object = obj };
}

/// Serializes phase command fields into an allocator-owned JSON value; allocation failures propagate.
pub fn phaseCommandValue(allocator: std.mem.Allocator, phase: workflows.PhaseRun) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (phase.outcome) {
        .result => |result| try commandResultValue(allocator, phase.name, phase.argv.items, phase.cwd, phase.timeout_ms, .{
            .exit_code = result.exit_code,
            .term = result.term,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .duration_ms = result.duration_ms,
            .timed_out = result.timed_out,
            .stdout_truncated = result.stdout_truncated,
            .stderr_truncated = result.stderr_truncated,
        }),
        .port_error => |err| try commandErrorValue(allocator, phase.name, phase.argv.items, phase.cwd, phase.timeout_ms, err),
    };
}

/// Serializes phase events fields into an allocator-owned JSON value; allocation failures propagate.
pub fn phaseEventsValue(allocator: std.mem.Allocator, phase: workflows.PhaseRun) !std.json.Value {
    return switch (phase.outcome) {
        .result => |result| try buildEventsValue(allocator, "validation_phase", result.stderr, result.stdout, phase.argv.items, phase.ok, "executed_command"),
        .port_error => |err| try commandErrorEventsValue(allocator, "validation_phase", phase.argv.items, phase.cwd, phase.timeout_ms, err),
    };
}

/// Serializes history record fields into an allocator-owned JSON value; allocation failures propagate.
pub fn historyRecordValueFromUsecase(
    allocator: std.mem.Allocator,
    record: workflows.HistoryRecord,
    phases: []const workflows.PhaseRun,
    skipped: []const workflows.SkippedPhase,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var failures = std.json.Array.init(allocator);
    for (record.failures) |failure| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "phase", try ownedString(allocator, failure.phase));
        try obj.put(allocator, "fingerprint", try ownedString(allocator, failure.fingerprint));
        if (phaseByName(phases, failure.phase)) |phase| try obj.put(allocator, "command", try phaseCommandValue(allocator, phase));
        try failures.append(.{ .object = obj });
    }
    var slow = std.json.Array.init(allocator);
    for (record.slow_phases) |slow_phase| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "phase", try ownedString(allocator, slow_phase.phase));
        try obj.put(allocator, "duration_ms", .{ .integer = slow_phase.duration_ms });
        try slow.append(.{ .object = obj });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = workflows.schema_version });
    try obj.put(allocator, "recorded_unix_ms", .{ .integer = record.recorded_unix_ms });
    try obj.put(allocator, "ok", .{ .bool = record.ok });
    try obj.put(allocator, "plan_id", try ownedString(allocator, record.plan_id));
    try obj.put(allocator, "phase_count", .{ .integer = @intCast(record.phase_count) });
    try obj.put(allocator, "skipped_count", .{ .integer = @intCast(record.skipped_count) });
    try obj.put(allocator, "failures", .{ .array = failures });
    try obj.put(allocator, "slow_phases", .{ .array = slow });
    var phase_values = std.json.Array.init(allocator);
    for (phases) |phase| try phase_values.append(try validationPhaseRunValue(allocator, phase));
    try obj.put(allocator, "phases", .{ .array = phase_values });
    try obj.put(allocator, "skipped_phases", try skippedPhasesValue(allocator, skipped));
    return .{ .object = obj };
}

/// Serializes preimage fields into an allocator-owned JSON value; allocation failures propagate.
pub fn preimageValueFromUsecase(allocator: std.mem.Allocator, preimage: workflows.Preimage) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "exists", .{ .bool = preimage.exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(preimage.bytes) });
    try obj.put(allocator, "sha256", if (preimage.sha256) |hash| try ownedString(allocator, hash) else .null);
    return .{ .object = obj };
}

/// Implements phase by name workflow logic using caller-owned inputs.
pub fn phaseByName(phases: []const workflows.PhaseRun, name: []const u8) ?workflows.PhaseRun {
    for (phases) |phase| {
        if (std.mem.eql(u8, phase.name, name)) return phase;
    }
    return null;
}

/// Serializes history runs array fields into an allocator-owned JSON value; allocation failures propagate.
pub fn historyRunsArrayValue(allocator: std.mem.Allocator, runs: []const workflows.HistoryRun) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (runs) |run_item| try array.append(try historyRunJsonValue(allocator, run_item));
    return .{ .array = array };
}

/// Serializes history run json fields into an allocator-owned JSON value; allocation failures propagate.
pub fn historyRunJsonValue(allocator: std.mem.Allocator, run_item: workflows.HistoryRun) !std.json.Value {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, run_item.raw_json, .{}) catch return ownedString(allocator, run_item.raw_json);
    defer parsed.deinit();
    return cloneValue(allocator, parsed.value);
}

/// Serializes failure groups fields into an allocator-owned JSON value; allocation failures propagate.
pub fn failureGroupsValueFromUsecase(allocator: std.mem.Allocator, groups: []const workflows.FailureGroup) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var array = std.json.Array.init(allocator);
    for (groups) |group| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "fingerprint", try ownedString(allocator, group.fingerprint));
        try obj.put(allocator, "count", .{ .integer = @intCast(group.count) });
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, group.sample_json, .{}) catch null;
        if (parsed) |*value| {
            defer value.deinit();
            try obj.put(allocator, "sample", try cloneValue(allocator, value.value));
        } else {
            try obj.put(allocator, "sample", try ownedString(allocator, group.sample_json));
        }
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

/// Serializes command result fields into an allocator-owned JSON value; allocation failures propagate.
pub fn commandResultValue(
    allocator: std.mem.Allocator,
    title: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    timeout_ms: i64,
    result: ports.CommandResult,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const term = result.effectiveTerm();
    const ok = !term.failed() and !result.timed_out;
    try obj.put(allocator, "kind", .{ .string = "command" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvOwnedValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "duration_ms", .{ .integer = @intCast(result.duration_ms) });
    try obj.put(allocator, "term", try commandTermValue(allocator, term));
    const stdout = try safeTextAlloc(allocator, result.stdout);
    const stderr = try safeTextAlloc(allocator, result.stderr);
    try putStreamFields(allocator, &obj, "stdout", stdout);
    try putStreamFields(allocator, &obj, "stderr", stderr);
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(workflows.command_output_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(workflows.command_output_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = "truncate_on_limit" });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = result.stdout_truncated or result.stderr_truncated });
    if (result.stdout_truncated or result.stderr_truncated) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigars' capture limit. zigars returned the captured prefix and marked the truncated stream so the result remains inspectable." });
    }
    const insights = try project_values.compilerInsightsValue(allocator, stdout.text, stderr.text, argv);
    try obj.put(allocator, "diagnostics", insights);
    try obj.put(allocator, "failure_summary", try failureSummaryValue(allocator, insights, ok, argv));
    return .{ .object = obj };
}

/// Serializes command error fields into an allocator-owned JSON value; allocation failures propagate.
pub fn commandErrorValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, err: anyerror) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "command_error" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try argvOwnedValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = commandErrorKind(err) });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(workflows.command_output_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(workflows.command_output_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = "truncate_on_limit" });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = isOutputLimitError(err) });
    try obj.put(allocator, "stdout_truncated", .{ .bool = false });
    try obj.put(allocator, "stderr_truncated", .{ .bool = false });
    if (isOutputLimitError(err)) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigars' capture limit before zigars could retain a bounded prefix. Narrow the command or run it directly when full output is needed." });
    }
    try obj.put(allocator, "failure_summary", try commandErrorSummaryValue(allocator, err, argv));
    return .{ .object = obj };
}

/// Serializes failure summary fields into an allocator-owned JSON value; allocation failures propagate.
pub fn failureSummaryValue(allocator: std.mem.Allocator, insights: std.json.Value, ok: bool, argv: []const []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
        if (project_values.argvContains(argv, "test")) try suggested.append(try ownedString(allocator, "zig_test_failure_triage"));
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
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "primary", .null);
    try obj.put(allocator, "error_class", .{ .string = commandErrorKind(err) });
    try obj.put(allocator, "rerun_command", .{ .string = try project_values.commandString(allocator, argv) });
    var suggested = std.json.Array.init(allocator);
    try suggested.append(try ownedString(allocator, "zigars_doctor"));
    try suggested.append(try ownedString(allocator, "zigars_context_pack"));
    try obj.put(allocator, "suggested_tools", .{ .array = suggested });
    try obj.put(allocator, "likely_scope", .{ .string = if (isTimeoutError(err)) "command_timeout" else "tool_or_backend_configuration" });
    return .{ .object = obj };
}

/// Serializes likely failure scope fields into an allocator-owned JSON value; allocation failures propagate.
pub fn likelyFailureScopeValue(allocator: std.mem.Allocator, primary: std.json.Value) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const primary_obj = switch (primary) {
        .object => |o| o,
        else => return .{ .string = "none" },
    };
    const path = stringField(primary_obj, "path") orelse return .{ .string = "workspace_or_build" };
    if (std.mem.eql(u8, path, "build.zig") or std.mem.eql(u8, path, "build.zig.zon")) return .{ .string = "build_configuration" };
    if (std.mem.endsWith(u8, path, ".zig")) return .{ .string = "source_file" };
    return .{ .string = try std.fmt.allocPrint(allocator, "path:{s}", .{path}) };
}

/// Serializes build events fields into an allocator-owned JSON value; allocation failures propagate.
pub fn buildEventsValue(allocator: std.mem.Allocator, tool_name: []const u8, stderr: []const u8, stdout: []const u8, argv: []const []const u8, ok: bool, basis: []const u8) !std.json.Value {
    // Construct this value in a single path so required fields cannot drift.
    var events = std.json.Array.init(allocator);
    try collectLineEvents(allocator, &events, stderr, "stderr");
    try collectLineEvents(allocator, &events, stdout, "stdout");
    const compiler = try project_values.compilerInsightsValue(allocator, stdout, stderr, argv);
    const tests = try project_values.testFailureTriageValue(allocator, stderr, stdout, argv, ok);
    var timings = try timingValue(allocator, stderr);
    const stdout_timings = try timingValue(allocator, stdout);
    try timings.array.appendSlice(stdout_timings.array.items);
    const compiler_error_count: i64 = if (compiler.object.get("error_count")) |value| switch (value) {
        .integer => |n| n,
        else => 0,
    } else 0;
    const test_failure_count: usize = if (tests.object.get("failures")) |value| switch (value) {
        .array => |failures| failures.items.len,
        else => 0,
    } else 0;
    var summary = std.json.ObjectMap.empty;
    try summary.put(allocator, "event_count", .{ .integer = @intCast(events.items.len) });
    try summary.put(allocator, "compiler_error_count", .{ .integer = compiler_error_count });
    try summary.put(allocator, "test_failure_count", .{ .integer = @intCast(test_failure_count) });
    try summary.put(allocator, "timing_count", .{ .integer = @intCast(timings.array.items.len) });

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", try ownedString(allocator, tool_name));
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "argv", try argvOwnedValue(allocator, argv));
    try obj.put(allocator, "parsing_basis", try ownedString(allocator, basis));
    try obj.put(allocator, "events", .{ .array = events });
    try obj.put(allocator, "compiler", compiler);
    try obj.put(allocator, "tests", tests);
    try obj.put(allocator, "timings", timings);
    try obj.put(allocator, "summary", .{ .object = summary });
    try obj.put(allocator, "confidence", .{ .string = if (std.mem.eql(u8, basis, "executed_command")) "high" else "medium" });
    try obj.put(allocator, "limitations", .{ .string = "Event parsing is best-effort over Zig stdout/stderr; raw command output remains the audit source." });
    return .{ .object = obj };
}

/// Serializes command error events fields into an allocator-owned JSON value; allocation failures propagate.
pub fn commandErrorEventsValue(allocator: std.mem.Allocator, tool_name: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, err: anyerror) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", try ownedString(allocator, tool_name));
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "command", try commandErrorValue(allocator, tool_name, argv, cwd, timeout_ms, err));
    try obj.put(allocator, "events", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "error_kind", .{ .string = commandErrorKind(err) });
    try obj.put(allocator, "resolution", .{ .string = "Confirm the configured Zig executable and workspace command can run, or pass captured output as text." });
    return .{ .object = obj };
}

/// Collects line events data into caller-provided output storage without taking ownership of inputs.
pub fn collectLineEvents(allocator: std.mem.Allocator, events: *std.json.Array, text_value: []const u8, stream: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var lines = std.mem.splitScalar(u8, text_value, '\n');
    var line_no: usize = 1;
    while (lines.next()) |raw| : (line_no += 1) {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const event_type = classifyEventLine(line);
        if (std.mem.eql(u8, event_type, "output")) continue;
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "line", .{ .integer = @intCast(line_no) });
        try obj.put(allocator, "stream", try ownedString(allocator, stream));
        try obj.put(allocator, "event", try ownedString(allocator, event_type));
        try obj.put(allocator, "message", try ownedString(allocator, line));
        try events.append(.{ .object = obj });
    }
}

/// Classifies a command output line for validation event summaries.
pub fn classifyEventLine(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, ": error: ") != null or std.mem.startsWith(u8, line, "error: ")) return "compiler_error";
    if (std.mem.indexOf(u8, line, ": warning: ") != null or std.mem.startsWith(u8, line, "warning: ")) return "compiler_warning";
    if (std.mem.indexOf(u8, line, "FAIL") != null or std.mem.indexOf(u8, line, "failed") != null) return "test_failure";
    if (std.mem.indexOf(u8, line, "PASS") != null or std.mem.indexOf(u8, line, "passed") != null) return "test_pass";
    if (std.mem.indexOf(u8, line, "Step ") != null) return "build_step";
    return "output";
}

/// Serializes timing fields into an allocator-owned JSON value; allocation failures propagate.
pub fn timingValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var timings = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (parseDurationMs(line)) |ms| {
            var obj = std.json.ObjectMap.empty;
            try obj.put(allocator, "name", try ownedString(allocator, line));
            try obj.put(allocator, "duration_ms", .{ .integer = ms });
            try obj.put(allocator, "source", .{ .string = "text" });
            try timings.append(.{ .object = obj });
        }
    }
    return .{ .array = timings };
}

/// Parses duration ms input using caller-provided storage; malformed input and allocation failures propagate.
pub fn parseDurationMs(line: []const u8) ?i64 {
    if (std.mem.indexOf(u8, line, "ms")) |ms_pos| {
        var start = ms_pos;
        while (start > 0 and std.ascii.isDigit(line[start - 1])) start -= 1;
        if (start < ms_pos) return std.fmt.parseInt(i64, line[start..ms_pos], 10) catch null;
    }
    return null;
}

/// Constructs explain argv data from caller-owned inputs, propagating allocation failures.
pub fn buildExplainArgv(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, request: FailureFusionRequest) !ArgvList {
    return buildZigArgv(allocator, context, request.command orelse if (request.file == null) "build-test" else "check", request.file, request.filter, request.extra_args);
}

/// Constructs event argv data from caller-owned inputs, propagating allocation failures.
pub fn buildEventArgv(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, request: CommandEventsRequest) !ArgvList {
    const command_name = request.command orelse switch (request.kind) {
        .build => "build-test",
        .test_cmd => "test",
    };
    return buildZigArgv(allocator, context, command_name, request.file, request.filter, request.extra_args);
}

/// Constructs zig argv data from caller-owned inputs, propagating allocation failures.
pub fn buildZigArgv(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    command_name: []const u8,
    file: ?[]const u8,
    filter: ?[]const u8,
    extra_args: []const []const u8,
) !ArgvList {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        freeStringList(allocator, list.items);
        list.deinit(allocator);
    }
    try appendOwnedArg(allocator, &list, context.tool_paths.zig);
    if (std.mem.eql(u8, command_name, "build")) {
        try appendOwnedArg(allocator, &list, "build");
    } else if (std.mem.eql(u8, command_name, "build-test")) {
        try appendOwnedArg(allocator, &list, "build");
        try appendOwnedArg(allocator, &list, "test");
    } else if (std.mem.eql(u8, command_name, "check")) {
        try appendOwnedArg(allocator, &list, "ast-check");
        const file_value = file orelse return error.MissingFile;
        const resolved = try context.workspace_store.resolve(allocator, .{
            .path = file_value,
            .provenance = "project_intelligence.command_arg",
        });
        defer resolved.deinit(allocator);
        try appendOwnedArg(allocator, &list, resolved.path);
    } else if (std.mem.eql(u8, command_name, "fmt-check")) {
        try appendOwnedArg(allocator, &list, "fmt");
        try appendOwnedArg(allocator, &list, "--check");
        // Resolve a caller-supplied path through the workspace sandbox before it
        // reaches the `zig fmt --check` argv, matching the `check`/`test`
        // branches. Without this, a raw `../../etc/hosts` would escape the
        // workspace boundary the tool advertises. The `src` default is preserved
        // when no path is supplied.
        if (file) |file_value| {
            const resolved = try context.workspace_store.resolve(allocator, .{
                .path = file_value,
                .provenance = "project_intelligence.command_arg",
            });
            defer resolved.deinit(allocator);
            try appendOwnedArg(allocator, &list, resolved.path);
        } else try appendOwnedArg(allocator, &list, "src");
    } else if (std.mem.eql(u8, command_name, "test")) {
        try appendOwnedArg(allocator, &list, "test");
        const file_value = file orelse return error.MissingFile;
        const resolved = try context.workspace_store.resolve(allocator, .{
            .path = file_value,
            .provenance = "project_intelligence.command_arg",
        });
        defer resolved.deinit(allocator);
        try appendOwnedArg(allocator, &list, resolved.path);
        if (filter) |filter_value| {
            try appendOwnedArg(allocator, &list, "--test-filter");
            try appendOwnedArg(allocator, &list, filter_value);
        }
    } else return error.InvalidCommand;
    try appendExtraArgs(allocator, &list, command_name, extra_args);
    return .{ .items = try list.toOwnedSlice(allocator) };
}

/// Path-bearing `zig build`-system flags that would redirect compilation,
/// caching, emitted output, package/library resolution, or the build runner
/// itself outside the workspace sandbox (the last enabling arbitrary code
/// execution).
///
/// There is no shell on this surface, so user tokens cannot inject commands —
/// but they can inject *flags* to the fixed `zig` binary. These flags take a
/// filesystem operand (as `--flag value`, `--flag=value`, or, for `-femit-*`,
/// `-femit-bin=path`) that escapes the write/exec boundary the rest of the
/// server enforces, so they are denied in the passthrough.
const denied_build_flag_prefixes = [_][]const u8{
    "--build-file",
    "--prefix",
    "--cache-dir",
    "--global-cache-dir",
    "--zig-lib-dir",
    "-femit-",
    // `--prefix-lib-dir` / `--prefix-exe-dir` / `--prefix-include-dir` also
    // redirect install output; they share the `--prefix` stem above only as a
    // separate token, so list them explicitly.
    "--prefix-lib-dir",
    "--prefix-exe-dir",
    "--prefix-include-dir",
    // `-p` is the documented short alias of `--prefix` (`zig build -h`:
    // "-p, --prefix [path]"), so it redirects install output just like
    // `--prefix`. Zig only accepts its operand space-separated (`-p <path>`);
    // the glued `-p<path>` and `-p=<path>` forms are rejected by the build
    // runner as unrecognized, so the exact-token / `=` matching below is exactly
    // the live surface.
    "-p",
    // `--build-runner [file]` overrides the build runner with an arbitrary Zig
    // file, executing attacker-chosen code outside the workspace — strictly
    // worse than the already-denied `--build-file`.
    "--build-runner",
    // System-integration flags that take a path operand (`zig build -h`,
    // "System Integration Options"). Each points compilation, linking, libc, or
    // package resolution at a directory or file outside the workspace, so they
    // can both read host paths and pull in foreign build/link inputs.
    "--search-prefix",
    "--sysroot",
    "--libc",
    "--libc-runtimes",
    "--system",
};

/// Returns true when `arg` is (or begins, for `--flag=value`/`-femit-*` forms) a
/// denied path-bearing build-system flag.
pub fn isDeniedBuildFlag(arg: []const u8) bool {
    for (denied_build_flag_prefixes) |flag| {
        if (std.mem.eql(u8, arg, flag)) return true;
        // `--cache-dir=foo` and `-femit-bin=foo` carry the operand inline.
        if (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len) {
            const next = arg[flag.len];
            if (next == '=' or std.mem.startsWith(u8, flag, "-femit-")) return true;
        }
    }
    return false;
}

/// Appends caller-supplied passthrough tokens to the assembled argv with a
/// sandbox guard appropriate to the subcommand.
///
/// - `zig test`: a `--` end-of-options separator is inserted first, so every
///   following token is handed to the compiled test binary rather than
///   interpreted as a compiler flag. `zig test --` does not carry run-step
///   semantics, so this is both safe and sufficient.
/// - `zig build` / `zig build test` and the `zig ast-check` / `zig fmt`
///   helpers: `--` is *not* added (for `zig build` it would mean "arguments to
///   the run step"). Instead path-bearing build-system flags that escape the
///   workspace are rejected outright, failing closed.
pub fn appendExtraArgs(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    command_name: []const u8,
    extra_args: []const []const u8,
) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    if (extra_args.len == 0) return;
    if (std.mem.eql(u8, command_name, "test")) {
        try appendOwnedArg(allocator, list, "--");
        for (extra_args) |arg| try appendOwnedArg(allocator, list, arg);
        return;
    }
    for (extra_args) |arg| {
        if (isDeniedBuildFlag(arg)) return error.UnsafeBuildFlag;
        try appendOwnedArg(allocator, list, arg);
    }
}

/// Appends owned arg data into caller-provided storage, propagating allocation failures.
pub fn appendOwnedArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    try list.append(allocator, try allocator.dupe(u8, value));
}

/// Appends validation phase data into caller-provided storage, propagating allocation failures.
pub fn appendValidationPhase(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    phases: *std.json.Array,
    name: []const u8,
    argv: []const []const u8,
    timeout_ms: i64,
) !bool {
    // Append in deterministic order so completion and snapshot output remain stable.
    var result = context.command_runner.run(allocator, .{
        .argv = argv,
        .cwd = context.workspace.root,
        .timeout_ms = @intCast(@max(1, timeout_ms)),
        .max_stdout_bytes = workflows.command_output_limit,
        .max_stderr_bytes = workflows.command_output_limit,
        .provenance = "zigars_validate_patch phase",
    }) catch |err| {
        var phase = std.json.ObjectMap.empty;
        try phase.put(allocator, "name", .{ .string = name });
        try phase.put(allocator, "ok", .{ .bool = false });
        try phase.put(allocator, "command", try commandErrorValue(allocator, name, argv, context.workspace.root, timeout_ms, err));
        try phases.append(.{ .object = phase });
        return false;
    };
    defer result.deinit(allocator);
    const term = result.effectiveTerm();
    const ok = !term.failed() and !result.timed_out;
    var phase = std.json.ObjectMap.empty;
    try phase.put(allocator, "name", .{ .string = name });
    try phase.put(allocator, "ok", .{ .bool = ok });
    try phase.put(allocator, "command", try commandResultValue(allocator, name, argv, context.workspace.root, timeout_ms, result));
    try phases.append(.{ .object = phase });
    return ok;
}

/// Appends workspace format check phase data into caller-provided storage, propagating allocation failures.
pub fn appendWorkspaceFormatCheckPhase(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    phases: *std.json.Array,
    timeout_ms: i64,
    ok: *bool,
    stop_on_failure: bool,
) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    const candidates = [_][]const u8{ "build.zig", "build.zig.zon", "src" };
    var argv_list: std.ArrayList([]const u8) = .empty;
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, context.tool_paths.zig);
    try argv_list.append(allocator, "fmt");
    try argv_list.append(allocator, "--check");
    var appended = false;
    for (candidates) |candidate| {
        if (!workspacePathExists(allocator, context, candidate)) continue;
        try argv_list.append(allocator, candidate);
        appended = true;
    }
    if (!appended) return;
    const fmt_ok = try appendValidationPhase(allocator, context, phases, "workspace_format_check", argv_list.items, timeout_ms);
    if (!fmt_ok) {
        ok.* = false;
        if (stop_on_failure) return;
    }
}

/// Appends workspace format check command data into caller-provided storage, propagating allocation failures.
pub fn appendWorkspaceFormatCheckCommand(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, commands: *std.json.Array) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    const candidates = [_][]const u8{ "build.zig", "build.zig.zon", "src" };
    var command_text: std.ArrayList(u8) = .empty;
    defer command_text.deinit(allocator);
    try command_text.appendSlice(allocator, "zig fmt --check");
    var appended_path = false;
    for (candidates) |candidate| {
        if (!workspacePathExists(allocator, context, candidate)) continue;
        try command_text.print(allocator, " {s}", .{candidate});
        appended_path = true;
    }
    if (appended_path) try appendUniqueCommand(allocator, commands, command_text.items);
}

/// Serializes skipped phase fields into an allocator-owned JSON value; allocation failures propagate.
pub fn skippedPhaseValue(allocator: std.mem.Allocator, name: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "reason", .{ .string = reason });
    return .{ .object = obj };
}

/// Serializes skipped step fields into an allocator-owned JSON value; allocation failures propagate.
pub fn skippedStepValue(allocator: std.mem.Allocator, name: []const u8, reason: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    return .{ .object = obj };
}

/// Appends unique file object data into caller-provided storage, propagating allocation failures.
pub fn appendUniqueFileObject(allocator: std.mem.Allocator, out: *std.json.Array, file: []const u8, reason: []const u8, confidence: []const u8) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    for (out.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (std.mem.eql(u8, stringField(obj, "file") orelse "", file)) return;
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    try obj.put(allocator, "confidence", .{ .string = confidence });
    try out.append(.{ .object = obj });
}

/// Collects importers for file data into caller-provided output storage without taking ownership of inputs.
pub fn collectImportersForFile(allocator: std.mem.Allocator, imports_value: std.json.Value, out: *std.json.Array, target: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const imports = switch (imports_value) {
        .array => |a| a,
        else => return,
    };
    for (imports.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const imported = stringField(obj, "import") orelse "";
        if (!importMatchesTarget(imported, target)) continue;
        const file = stringField(obj, "file") orelse continue;
        try appendImpactMatch(allocator, out, file, target, "imports_changed_file", "parser", "high");
    }
}

/// Collects tests for file data into caller-provided output storage without taking ownership of inputs.
pub fn collectTestsForFile(allocator: std.mem.Allocator, tests_value: std.json.Value, out: *std.json.Array, target: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const tests = switch (tests_value) {
        .array => |a| a,
        else => return,
    };
    for (tests.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const file = stringField(obj, "file") orelse continue;
        if (std.mem.eql(u8, file, target) or referencesFileStem(stringField(obj, "name") orelse "", target)) {
            try appendImpactMatch(allocator, out, file, target, "test_matches_changed_file", "parser", "high");
        }
    }
}

/// Collects public api for file data into caller-provided output storage without taking ownership of inputs.
pub fn collectPublicApiForFile(allocator: std.mem.Allocator, decls_value: std.json.Value, out: *std.json.Array, target: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const decls = switch (decls_value) {
        .array => |a| a,
        else => return,
    };
    for (decls.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (!std.mem.eql(u8, stringField(obj, "file") orelse "", target)) continue;
        if (!(boolField(obj, "public") orelse false)) continue;
        try out.append(try cloneValue(allocator, item));
    }
}

/// Collects declarations for symbol data into caller-provided output storage without taking ownership of inputs.
pub fn collectDeclarationsForSymbol(allocator: std.mem.Allocator, decls_value: std.json.Value, out: *std.json.Array, symbol: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const decls = switch (decls_value) {
        .array => |a| a,
        else => return,
    };
    for (decls.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = stringField(obj, "name") orelse "";
        const signature = stringField(obj, "signature") orelse "";
        if (std.mem.indexOf(u8, name, symbol) == null and std.mem.indexOf(u8, signature, symbol) == null) continue;
        try out.append(try cloneValue(allocator, item));
    }
}

/// Collects tests for symbol data into caller-provided output storage without taking ownership of inputs.
pub fn collectTestsForSymbol(allocator: std.mem.Allocator, tests_value: std.json.Value, out: *std.json.Array, symbol: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const tests = switch (tests_value) {
        .array => |a| a,
        else => return,
    };
    for (tests.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const name = stringField(obj, "name") orelse "";
        const file = stringField(obj, "file") orelse "";
        if (std.mem.indexOf(u8, name, symbol) == null and std.mem.indexOf(u8, file, symbol) == null) continue;
        try appendImpactMatch(allocator, out, file, symbol, "test_matches_symbol", "parser", "high");
    }
}

/// Appends impact match data into caller-provided storage, propagating allocation failures.
pub fn appendImpactMatch(allocator: std.mem.Allocator, out: *std.json.Array, file: []const u8, target: []const u8, reason: []const u8, source: []const u8, confidence: []const u8) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    for (out.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (std.mem.eql(u8, stringField(obj, "file") orelse "", file) and std.mem.eql(u8, stringField(obj, "target") orelse "", target) and std.mem.eql(u8, stringField(obj, "reason") orelse "", reason)) return;
    }
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "target", try ownedString(allocator, target));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    try obj.put(allocator, "source", .{ .string = source });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    try out.append(.{ .object = obj });
}

/// Appends commands from matches data into caller-provided storage, propagating allocation failures.
pub fn appendCommandsFromMatches(allocator: std.mem.Allocator, commands: *std.json.Array, matches: std.json.Array) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    for (matches.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const file = stringField(obj, "file") orelse continue;
        if (std.mem.endsWith(u8, file, ".zig")) try appendUniqueCommand(allocator, commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{file}));
    }
}

/// Appends commands for impact data into caller-provided storage, propagating allocation failures.
pub fn appendCommandsForImpact(allocator: std.mem.Allocator, commands: *std.json.Array, reasons: *std.json.Array, value: std.json.Value, reason: []const u8) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    const array = switch (value) {
        .array => |a| a,
        else => return,
    };
    for (array.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const file = stringField(obj, "file") orelse continue;
        if (!std.mem.endsWith(u8, file, ".zig")) continue;
        try appendUniqueCommand(allocator, commands, try std.fmt.allocPrint(allocator, "zig test {s}", .{file}));
        try reasons.append(try ownedString(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ file, reason })));
    }
}

/// Reports whether an `@import` path likely refers to the target file: exact
/// match, basename match, or basename-substring. Heuristic, so it can over-match
/// (e.g. similarly named files); callers treat hits as advisory.
pub fn importMatchesTarget(imported: []const u8, target: []const u8) bool {
    const base = std.fs.path.basename(target);
    return std.mem.eql(u8, imported, target) or
        std.mem.eql(u8, imported, base) or
        std.mem.indexOf(u8, imported, base) != null;
}

/// Serializes profile state fields into an allocator-owned JSON value; allocation failures propagate.
pub fn profileStateValue(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "profile_v2_path", .{ .string = ".zigars/profile.v2.json" });
    if (context.workspace_store.read(allocator, .{ .path = ".zigars/profile.v2.json", .max_bytes = 1024 * 1024, .provenance = "project_intelligence.profile_state" }) catch null) |read_result| {
        defer read_result.deinit(allocator);
        try obj.put(allocator, "profile_v2_present", .{ .bool = true });
        try obj.put(allocator, "sha256", .{ .string = try sha256Hex(allocator, read_result.bytes) });
    } else {
        try obj.put(allocator, "profile_v2_present", .{ .bool = false });
        try obj.put(allocator, "sha256", .null);
    }
    return .{ .object = obj };
}

/// Serializes decision record data fields into an allocator-owned JSON value; allocation failures propagate.
pub fn decisionRecordDataValue(
    allocator: std.mem.Allocator,
    context: app_context.ProjectIntelligenceContext,
    title: []const u8,
    decision: []const u8,
    rationale: ?[]const u8,
    category: []const u8,
) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const instant = try context.clock_and_ids.now();
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "id", try ownedString(allocator, try std.fmt.allocPrint(allocator, "decision-{d}", .{instant.unix_ms})));
    try obj.put(allocator, "category", try ownedString(allocator, category));
    try obj.put(allocator, "title", try ownedString(allocator, title));
    try obj.put(allocator, "decision", try ownedString(allocator, decision));
    try obj.put(allocator, "rationale", if (rationale) |value| try ownedString(allocator, value) else .null);
    try obj.put(allocator, "source", .{ .string = "zigars_decision_record" });
    return .{ .object = obj };
}

/// Builds preimage identity metadata for the requested workspace path.
pub fn preimageIdentityForPath(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, path: []const u8) !std.json.Value {
    // Normalize and constrain path handling here before any downstream filesystem action.
    const read_result = context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = 8 * 1024 * 1024,
        .provenance = "project_intelligence.preimage",
    }) catch return preimageValue(allocator, false, 0, "");
    defer read_result.deinit(allocator);
    const hash = try sha256Hex(allocator, read_result.bytes);
    return preimageValue(allocator, true, read_result.bytes.len, hash);
}

/// Serializes preimage fields into an allocator-owned JSON value; allocation failures propagate.
pub fn preimageValue(allocator: std.mem.Allocator, exists: bool, bytes: usize, sha256: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes) });
    try obj.put(allocator, "sha256", if (sha256.len > 0) try ownedString(allocator, sha256) else .null);
    return .{ .object = obj };
}

/// Parses json value or string input using caller-provided storage; malformed input and allocation failures propagate.
pub fn parseJsonValueOrString(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return ownedString(allocator, text);
    defer parsed.deinit();
    return cloneValue(allocator, parsed.value);
}

/// Reads json lines data from the provided context without taking ownership of inputs.
pub fn loadJsonLines(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, content: ?[]const u8, path: []const u8, limit: usize) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (content) |text| return .{ .array = try parseJsonLinesOrArray(allocator, text, limit) };
    const read_result = context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = 4 * 1024 * 1024,
        .provenance = "project_intelligence.project_memory",
    }) catch |err| switch (err) {
        error.FileNotFound, error.NotFound => return .{ .array = std.json.Array.init(allocator) },
        else => return err,
    };
    defer read_result.deinit(allocator);
    return .{ .array = try parseJsonLinesOrArray(allocator, read_result.bytes, limit) };
}

/// Parses json lines or array input using caller-provided storage; malformed input and allocation failures propagate.
pub fn parseJsonLinesOrArray(allocator: std.mem.Allocator, text: []const u8, limit: usize) !std.json.Array {
    // Normalize input here so downstream paths can rely on validated shape.
    var out = std.json.Array.init(allocator);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return out;
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed[0] == '[') {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
        defer parsed.deinit();
        const array = switch (parsed.value) {
            .array => |a| a,
            else => return out,
        };
        for (array.items) |item| {
            if (out.items.len >= limit) break;
            try out.append(try cloneValue(allocator, item));
        }
        return out;
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        if (out.items.len >= limit) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        try out.append(try cloneValue(allocator, parsed.value));
    }
    return out;
}

/// Filters project-memory records by optional category (exact) and query
/// (case-insensitive substring over title/decision/rationale/category), capped
/// at `limit`. Returns an allocator-owned JSON array of cloned matches.
pub fn filterRecords(allocator: std.mem.Allocator, records: std.json.Value, query: ?[]const u8, category: ?[]const u8, limit: usize) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const array = switch (records) {
        .array => |a| a,
        else => return .{ .array = std.json.Array.init(allocator) },
    };
    const lower_query = if (query) |q| try std.ascii.allocLowerString(allocator, q) else "";
    var out = std.json.Array.init(allocator);
    for (array.items) |item| {
        if (out.items.len >= limit) break;
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (category) |cat| if (!std.mem.eql(u8, stringField(obj, "category") orelse "", cat)) continue;
        if (query != null) {
            const hay = try std.ascii.allocLowerString(allocator, try searchableRecordText(allocator, obj));
            if (std.mem.indexOf(u8, hay, lower_query) == null) continue;
        }
        try out.append(try cloneValue(allocator, item));
    }
    return .{ .array = out };
}

/// Concatenates a record's title/decision/rationale/category into one
/// allocator-owned haystack string for substring query matching.
pub fn searchableRecordText(allocator: std.mem.Allocator, obj: std.json.ObjectMap) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} {s} {s} {s}", .{
        stringField(obj, "title") orelse "",
        stringField(obj, "decision") orelse "",
        stringField(obj, "rationale") orelse "",
        stringField(obj, "category") orelse "",
    });
}

/// Serializes built in project policies fields into an allocator-owned JSON value; allocation failures propagate.
pub fn builtInProjectPoliciesValue(allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    try array.append(try policyValue(allocator, "generated_paths", "Do not edit generated/cache outputs directly; change source or regeneration steps.", &.{ ".zig-cache", ".zigars-cache", "zig-out", "coverage" }));
    try array.append(try policyValue(allocator, "validation", "Treat skipped phases as unknown, not passed.", &.{ "zigars_validation_plan", "zigars_validation_run" }));
    try array.append(try policyValue(allocator, "writes", "Source and project-memory writes require explicit apply=true.", &.{"zigars_decision_record"}));
    return .{ .array = array };
}

/// Serializes policy fields into an allocator-owned JSON value; allocation failures propagate.
pub fn policyValue(allocator: std.mem.Allocator, name: []const u8, policy: []const u8, values: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", try ownedString(allocator, name));
    try obj.put(allocator, "policy", try ownedString(allocator, policy));
    try obj.put(allocator, "values", try stringArrayValue(allocator, values));
    return .{ .object = obj };
}

/// Scores a capability match against the requested task text.
pub fn matchScore(allocator: std.mem.Allocator, lower_goal: []const u8, entry: CapabilityEntry) !i64 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var score: i64 = 0;
    const lower_name = try std.ascii.allocLowerString(allocator, entry.name);
    if (std.mem.indexOf(u8, lower_goal, lower_name) != null) score += 10;
    const lower_desc = try std.ascii.allocLowerString(allocator, entry.description);
    var tokens = std.mem.tokenizeAny(u8, lower_goal, " \t\r\n,.;:/_-");
    while (tokens.next()) |token| {
        if (token.len < 3) continue;
        if (std.mem.indexOf(u8, lower_name, token) != null) score += 3;
        if (std.mem.indexOf(u8, lower_desc, token) != null) score += 1;
    }
    for (entry.group_keywords) |keyword| {
        const lower_keyword = try std.ascii.allocLowerString(allocator, keyword);
        if (std.mem.indexOf(u8, lower_goal, lower_keyword) != null) score += 2;
    }
    return score;
}

/// Appends capability match data into caller-provided storage, propagating allocation failures.
pub fn appendCapabilityMatch(allocator: std.mem.Allocator, matches: *std.json.Array, entry: CapabilityEntry, score: i64) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", try ownedString(allocator, entry.name));
    try obj.put(allocator, "score", .{ .integer = score });
    try obj.put(allocator, "confidence", .{ .string = if (score >= 8) "high" else if (score >= 3) "medium" else "low" });
    try obj.put(allocator, "group", .{ .string = entry.group });
    try obj.put(allocator, "risk", try riskValue(allocator, entry.risk));
    try obj.put(allocator, "plan_kind", .{ .string = entry.plan_kind });
    try obj.put(allocator, "description", try ownedString(allocator, entry.description));
    try matches.append(.{ .object = obj });
}

/// Serializes risk fields into an allocator-owned JSON value; allocation failures propagate.
pub fn riskValue(allocator: std.mem.Allocator, risk: ToolRisk) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "level", .{ .string = risk.level });
    try obj.put(allocator, "mcp_read_only_hint", .{ .bool = risk.mcp_read_only_hint });
    try obj.put(allocator, "writes_source", .{ .bool = risk.writes_source });
    try obj.put(allocator, "writes_artifacts", .{ .bool = risk.writes_artifacts });
    try obj.put(allocator, "writes_require_apply", .{ .bool = risk.writes_require_apply });
    try obj.put(allocator, "preview_by_default", .{ .bool = risk.preview_by_default });
    try obj.put(allocator, "mutates_lsp_state", .{ .bool = risk.mutates_lsp_state });
    try obj.put(allocator, "executes_project_code", .{ .bool = risk.executes_project_code });
    try obj.put(allocator, "executes_user_command", .{ .bool = risk.executes_user_command });
    try obj.put(allocator, "executes_backend", .{ .bool = risk.executes_backend });
    return .{ .object = obj };
}

/// Sorts matches data into deterministic result order.
pub fn sortMatches(matches: *std.json.Array) void {
    std.mem.sort(std.json.Value, matches.items, {}, struct {
        /// Orders matches by score for deterministic result sorting.
        fn lessThan(_: void, lhs: std.json.Value, rhs: std.json.Value) bool {
            const left = switch (lhs) {
                .object => |o| integerField(o, "score") orelse 0,
                else => 0,
            };
            const right = switch (rhs) {
                .object => |o| integerField(o, "score") orelse 0,
                else => 0,
            };
            return left > right;
        }
    }.lessThan);
}

/// Serializes sequence step fields into an allocator-owned JSON value; allocation failures propagate.
pub fn sequenceStepValue(allocator: std.mem.Allocator, tool: []const u8, reason: []const u8, executes: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "tool", try ownedString(allocator, tool));
    try obj.put(allocator, "reason", try ownedString(allocator, reason));
    try obj.put(allocator, "executes_project_code", .{ .bool = executes });
    return .{ .object = obj };
}

/// Writes the shared semantic-impact evidence envelope (analysis_kind, parser-
/// backed confidence, coverage, limitations, verify_with, cross-checks) onto a
/// result, branching on whether the tool is impact or test-selection. Keeps
/// these results honest: parser-backed yet advisory, never a skip-tests proof.
pub fn putSemanticMetadata(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, tool_name: []const u8) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const select = std.mem.eql(u8, tool_name, "zig_test_select_semantic");
    const analysis_kind = if (select) "parser_backed_semantic_test_selection" else "parser_backed_semantic_impact";
    try obj.put(allocator, "analysis_kind", .{ .string = analysis_kind });
    try obj.put(allocator, "capability_tier", .{ .string = "parser_backed" });
    try obj.put(allocator, "confidence", .{ .string = "high" });
    try obj.put(allocator, "confidence_class", .{ .string = "advisory" });
    try obj.put(allocator, "source_coverage", .{ .string = semantic_impact_coverage });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, semantic_impact_limits));
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, if (select) semantic_select_verify_with else semantic_impact_verify_with));
    try obj.put(allocator, "evidence_basis", try semanticEvidenceBasisValue(allocator, analysis_kind));
    try obj.put(allocator, "cross_check", try semanticCrossCheckValue(allocator, if (select) semantic_select_verify_with else semantic_impact_verify_with));
    try obj.put(allocator, "recommended_cross_check", .{ .string = if (select) semantic_select_verify_with[0] else semantic_impact_verify_with[0] });
}

const semantic_impact_coverage = "Readable workspace Zig files up to the requested limit; changed files, diff paths, symbols, imports, declarations, and tests are matched against the std.zig.Ast parser-backed semantic index; parse_status, partial_result, and parse_error_count are preserved with heuristic fallbacks called out explicitly.";
const semantic_impact_limits = &.{
    "Advisory impact and test-selection evidence; it does not prove that unselected tests can be skipped.",
    "Parse errors are reported through parser metadata when available and can make file-level impact evidence partial.",
    "Import matching uses parser-backed import declarations plus path/basename matching and can miss generated, aliased, or comptime-selected dependencies.",
    "Release decisions still require compiler-backed validation such as zig build test or project CI.",
};
const semantic_impact_verify_with = &.{ "zig ast-check on impacted files", "zig_test_select_semantic", "zigars_validation_plan", "zig build test" };
const semantic_select_verify_with = &.{ "zig ast-check on selected test files", "zigars_validation_run", "zig build test", "project CI" };

/// Serializes semantic evidence basis fields into an allocator-owned JSON value; allocation failures propagate.
pub fn semanticEvidenceBasisValue(allocator: std.mem.Allocator, analysis_kind: []const u8) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "analysis_kind", .{ .string = analysis_kind });
    try obj.put(allocator, "capability_tier", .{ .string = "parser_backed" });
    try obj.put(allocator, "confidence", .{ .string = "high" });
    try obj.put(allocator, "classification", .{ .string = "advisory" });
    try obj.put(allocator, "source_coverage", .{ .string = semantic_impact_coverage });
    return .{ .object = obj };
}

/// Serializes semantic cross check fields into an allocator-owned JSON value; allocation failures propagate.
pub fn semanticCrossCheckValue(allocator: std.mem.Allocator, verify_with: []const []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "required", .{ .bool = true });
    try obj.put(allocator, "verify_with", try stringArrayValue(allocator, verify_with));
    try obj.put(allocator, "reason", .{ .string = "Static analysis is advisory; compiler-backed validation remains the release gate." });
    return .{ .object = obj };
}

/// Collects a deduplicated path list from a whitespace/comma-separated `text`
/// argument plus paths parsed out of a unified `patch`. Returns an
/// allocator-owned PathList the caller must deinit.
pub fn pathListFromTextAndPatch(allocator: std.mem.Allocator, text: ?[]const u8, patch: ?[]const u8) !PathList {
    // Normalize and constrain path handling here before any downstream filesystem action.
    var paths = std.ArrayList([]const u8).empty;
    errdefer {
        freeStringList(allocator, paths.items);
        paths.deinit(allocator);
    }
    try appendPathTokens(allocator, &paths, text);
    try appendPatchPaths(allocator, &paths, patch);
    return .{ .items = try paths.toOwnedSlice(allocator) };
}

/// Determines the changed-file set: caller-supplied `explicit_files` win;
/// otherwise it falls back to `git status --porcelain` (bounded timeout),
/// dropping generated/vendored paths. A git failure yields an empty list rather
/// than an error. Returns an allocator-owned PathList the caller must deinit.
pub fn changedPathList(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, explicit_files: ?[]const u8, timeout_ms: i64) !PathList {
    // Normalize and constrain path handling here before any downstream filesystem action.
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        freeStringList(allocator, list.items);
        list.deinit(allocator);
    }
    try appendPathTokens(allocator, &list, explicit_files);
    if (list.items.len > 0) return .{ .items = try list.toOwnedSlice(allocator) };
    var result = context.command_runner.run(allocator, .{
        .argv = &.{ "git", "status", "--porcelain" },
        .cwd = context.workspace.root,
        .timeout_ms = @intCast(@max(1, @min(timeout_ms, 5000))),
        .max_stdout_bytes = workflows.command_output_limit,
        .max_stderr_bytes = workflows.command_output_limit,
        .provenance = "zigars_validate_patch changed paths",
    }) catch return .{ .items = try list.toOwnedSlice(allocator) };
    defer result.deinit(allocator);
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len < 4) continue;
        const path = statusLinePath(line);
        if (path.len == 0 or zig_analysis.skipWorkspacePath(path)) continue;
        try appendUniqueString(allocator, &list, path);
    }
    return .{ .items = try list.toOwnedSlice(allocator) };
}

/// Appends path tokens data into caller-provided storage, propagating allocation failures.
pub fn appendPathTokens(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), text_value: ?[]const u8) !void {
    const text_input = text_value orelse return;
    var tokens = std.mem.tokenizeAny(u8, text_input, ", \t\r\n");
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        try appendUniqueString(allocator, list, token);
    }
}

/// Appends patch paths data into caller-provided storage, propagating allocation failures.
pub fn appendPatchPaths(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), patch_text: ?[]const u8) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
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

/// Appends patch path token data into caller-provided storage, propagating allocation failures.
pub fn appendPatchPathToken(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), raw: []const u8) !void {
    var path = raw;
    if (std.mem.startsWith(u8, path, "a/") or std.mem.startsWith(u8, path, "b/")) path = path[2..];
    if (std.mem.eql(u8, path, "/dev/null")) return;
    try appendUniqueString(allocator, list, path);
}

/// Appends unique string data into caller-provided storage, propagating allocation failures.
pub fn appendUniqueString(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    if (stringListContains(list.items, value)) return;
    try list.append(allocator, try allocator.dupe(u8, value));
}

/// Appends unique command data into caller-provided storage, propagating allocation failures.
pub fn appendUniqueCommand(allocator: std.mem.Allocator, commands: *std.json.Array, command_text: []const u8) !void {
    // Append in deterministic order so completion and snapshot output remain stable.
    for (commands.items) |item| {
        const existing = switch (item) {
            .string => |s| s,
            else => continue,
        };
        if (std.mem.eql(u8, existing, command_text)) return;
    }
    try commands.append(try ownedString(allocator, command_text));
}

/// Extracts the path portion from a porcelain status line.
pub fn statusLinePath(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, if (line.len > 3) line[3..] else "", " \t");
    if (std.mem.indexOf(u8, trimmed, " -> ")) |arrow| return trimmed[arrow + " -> ".len ..];
    return trimmed;
}

/// Reports whether the requested workspace path exists.
pub fn workspacePathExists(allocator: std.mem.Allocator, context: app_context.ProjectIntelligenceContext, path: []const u8) bool {
    const result = context.workspace_store.exists(allocator, .{
        .path = path,
        .provenance = "project_intelligence.workspace_path_exists",
    }) catch return false;
    return result.exists;
}
