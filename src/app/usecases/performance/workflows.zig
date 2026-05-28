//! CLI-facing workflow handlers for performance evidence capture and analysis tools.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const support = @import("../usecase_support.zig");
const zig_analysis = @import("../../../domain/zig/analysis.zig");
const benchmark_model = @import("../../../domain/performance/benchmark_model.zig");
const benchmark_usecase = @import("benchmark.zig");
const coverage_model = @import("../../../domain/performance/coverage_model.zig");
const coverage_usecase = @import("coverage.zig");
const sessions = @import("../sessions/envelope.zig");

/// Aliases the app context wrapper used by this workflow module.
pub const App = support.UsecaseApp(app_context.PerformanceContext);
/// Aliases the structured result type returned by workflow entrypoints.
pub const Result = support.Result;
const CommandRunResult = support.CommandRunResult;
const artifacts = support.artifacts;
const argBool = support.argBool;
const argInt = support.argInt;
const argString = support.argString;
const argvValue = support.argvValue;
const backendErrorResult = support.backendErrorResult;
const backendUnavailableResult = support.backendUnavailableResult;
const checkBackend = support.checkBackend;
const changedPathList = support.changedPathList;
const cloneValue = support.cloneValue;
/// Aliases the shared command-error serializer for structured payloads.
const commandErrorValue = support.commandErrorValue;
/// Aliases the shared command-result serializer for structured payloads.
const commandResultValue = support.commandResultValue;
const freeStringList = support.freeStringList;
const missingArgumentResult = support.missingArgumentResult;
const runCommand = support.runCommand;
const recordArtifact = support.recordArtifact;
const serializeAlloc = support.serializeAlloc;
const splitToolArgs = support.splitToolArgs;
const splitToolArgsErrorResult = support.splitToolArgsErrorResult;
const structured = support.structured;
const toolErrorFromError = support.toolErrorFromError;
const toolTimeout = support.toolTimeout;
const unixMs = support.unixMs;
const workspacePathErrorResult = support.workspacePathErrorResult;

/// Schema version written into this module's structured payloads.
const schema_version = 1;
const max_evidence_bytes = 16 * 1024 * 1024;
const default_coverage_baseline = ".zigars-cache/coverage/baseline.json";
const default_bench_baseline = ".zigars-cache/benchmarks/baseline.json";
const default_bench_history = ".zigars-cache/benchmarks/history.json";
const bench_gate_session_kind = "bench_regression_gate";
const default_samply_profile = ".zigars-cache/profile/samply/profile.json";
const default_tracy_profile = ".zigars-cache/profile/tracy/capture.tracy";
const default_perf_evidence = ".zigars-cache/performance/evidence-pack.json";

/// Carries input data across use case and port boundaries.
const Input = struct {
    bytes: []const u8,
    source_kind: []const u8,
    path: ?[]const u8 = null,
    owned: ?[]u8 = null,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    fn deinit(self: Input, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| allocator.free(owned);
    }
};

const CoverageSet = coverage_model.CoverageSet;
const BenchSet = benchmark_model.BenchSet;

/// Invokes zig coverage run with caller-owned inputs; command and allocation failures propagate.
pub fn zigCoverageRun(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const command_text = argString(args, "command") orelse return missingArgumentResult(allocator, "zig_coverage_run", "command", "non-empty command string");
    const output = argString(args, "output") orelse ".zigars-cache/coverage/run.json";
    const apply = argBool(args, "apply", false);
    const timeout_ms = toolTimeout(a, args);
    const argv = splitToolArgs(allocator, command_text) catch |err| return splitToolArgsErrorResult(allocator, "zig_coverage_run", "command", command_text, err);
    defer freeArgv(allocator, argv);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    if (!apply) {
        var obj = std.json.ObjectMap.empty;
        try putBase(scratch, &obj, a, "zig_coverage_run", "Coverage command preview", "medium", &.{
            "The command is not executed until apply=true.",
            "Coverage format depends on the caller-supplied command and artifacts.",
        });
        try obj.put(scratch, "command_argv", try argvValue(scratch, argv));
        try obj.put(scratch, "target", stringOrNull(argString(args, "target")));
        try obj.put(scratch, "output", .{ .string = output });
        try obj.put(scratch, "applied", .{ .bool = false });
        try obj.put(scratch, "requires_apply", .{ .bool = true });
        try obj.put(scratch, "preimage_identity", preimageIdentityForPath(a, scratch, output) catch .null);
        try obj.put(scratch, "skipped_validation", try stringArrayValue(scratch, &.{"coverage command execution skipped by preview"}));
        return structured(allocator, .{ .object = obj });
    }
    const result = runCommand(allocator, a, argv, timeout_ms) catch |err| {
        const value = commandErrorValue(scratch, "coverage command", argv, a.workspace.root, timeout_ms, err) catch return error.OutOfMemory;
        return structured(allocator, value);
    };
    defer result.deinit(allocator);
    const command_result = commandResultValue(scratch, "coverage command", argv, a.workspace.root, timeout_ms, result) catch return error.OutOfMemory;
    const artifact_value = coverageRunArtifactValue(scratch, a, args, command_result) catch return error.OutOfMemory;
    const bytes = serializeAlloc(scratch, artifact_value) catch return error.OutOfMemory;
    const preimage_identity = preimageIdentityForPath(a, scratch, output) catch .null;
    writeAndRegisterArtifact(a, scratch, output, bytes, "zig_coverage_run", "coverage_run", argv, argString(args, "coverage_backend") orelse "caller_command", "", argString(args, "target") orelse "", "coverage run evidence") catch |err| return workspacePathErrorResult(a, allocator, "zig_coverage_run", output, err);

    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, a, "zig_coverage_run", "Executed caller-supplied coverage command", "medium", &.{
        "Coverage validity depends on the external command and produced artifacts.",
    });
    try obj.put(scratch, "command_result", command_result);
    try obj.put(scratch, "output", .{ .string = output });
    try obj.put(scratch, "artifact_identity", artifactIdentityValue(scratch, a, output, bytes) catch .null);
    try obj.put(scratch, "preimage_identity", preimage_identity);
    try obj.put(scratch, "applied", .{ .bool = true });
    try obj.put(scratch, "requires_apply", .{ .bool = false });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig coverage map workflow and returns an allocator-owned structured result.
pub fn zigCoverageMap(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_coverage_map", "coverage", "path", "content", true) catch |err| return evidenceInputError(a, allocator, "zig_coverage_map", args, "coverage", err);
    defer input.deinit(allocator);
    var set = coverage_usecase.map(allocator, .{
        .bytes = input.bytes,
        .source_kind = input.source_kind,
        .format = argString(args, "format") orelse "auto",
    }) catch |err| return performanceToolError(allocator, "zig_coverage_map", "parse_coverage", err);
    defer set.deinit(allocator);
    set.source_kind = input.source_kind;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = coverageMapValue(arena.allocator(), a, "zig_coverage_map", set, "Normalized coverage map", "high") catch return error.OutOfMemory;
    return structured(allocator, value);
}

/// Executes the zig coverage merge workflow and returns an allocator-owned structured result.
pub fn zigCoverageMerge(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const left_field = if (argString(args, "left") != null) "left" else "current";
    const right_field = if (argString(args, "right") != null) "right" else "baseline";
    var left_input = readEvidenceInput(a, allocator, args, "zig_coverage_merge", left_field, null, null, true) catch |err| return evidenceInputError(a, allocator, "zig_coverage_merge", args, left_field, err);
    defer left_input.deinit(allocator);
    var right_input = readEvidenceInput(a, allocator, args, "zig_coverage_merge", right_field, null, null, true) catch |err| return evidenceInputError(a, allocator, "zig_coverage_merge", args, right_field, err);
    defer right_input.deinit(allocator);
    var merged = coverage_usecase.merge(allocator, .{
        .left = .{ .bytes = left_input.bytes, .source_kind = left_input.source_kind },
        .right = .{ .bytes = right_input.bytes, .source_kind = right_input.source_kind },
    }) catch |err| return performanceToolError(allocator, "zig_coverage_merge", "merge_coverage", err);
    defer merged.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const coverage = coverageMapValue(scratch, a, "zig_coverage_merge", merged, "Merged coverage evidence", "high") catch return error.OutOfMemory;
    return maybeWriteArtifact(a, allocator, scratch, args, "zig_coverage_merge", coverage, argString(args, "output") orelse ".zigars-cache/coverage/merged.json", "coverage_merged", &.{});
}

/// Executes the zig coverage diff workflow and returns an allocator-owned structured result.
pub fn zigCoverageDiff(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var current_input = readEvidenceInput(a, allocator, args, "zig_coverage_diff", "current", null, null, true) catch |err| return evidenceInputError(a, allocator, "zig_coverage_diff", args, "current", err);
    defer current_input.deinit(allocator);
    var baseline_input = readEvidenceInput(a, allocator, args, "zig_coverage_diff", "baseline", null, null, true) catch |err| return evidenceInputError(a, allocator, "zig_coverage_diff", args, "baseline", err);
    defer baseline_input.deinit(allocator);
    var diff = coverage_usecase.diff(allocator, .{
        .current = .{ .bytes = current_input.bytes, .source_kind = current_input.source_kind },
        .baseline = .{ .bytes = baseline_input.bytes, .source_kind = baseline_input.source_kind },
    }) catch |err| return performanceToolError(allocator, "zig_coverage_diff", "diff_coverage", err);
    defer diff.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = coverageDiffValue(arena.allocator(), a, diff) catch return error.OutOfMemory;
    return structured(allocator, value);
}

/// Executes the zig coverage baseline workflow and returns an allocator-owned structured result.
pub fn zigCoverageBaseline(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_coverage_baseline", "coverage", "path", "content", true) catch |err| return evidenceInputError(a, allocator, "zig_coverage_baseline", args, "coverage", err);
    defer input.deinit(allocator);
    var set = coverage_usecase.map(allocator, .{
        .bytes = input.bytes,
        .source_kind = input.source_kind,
        .format = argString(args, "format") orelse "auto",
    }) catch |err| return performanceToolError(allocator, "zig_coverage_baseline", "parse_coverage", err);
    defer set.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, a, "zig_coverage_baseline", "Coverage baseline snapshot", "high", &.{
        "Baseline quality depends on the supplied coverage evidence.",
    });
    try obj.put(scratch, "baseline_identity", .{ .string = argString(args, "baseline_id") orelse "workspace-current" });
    try obj.put(scratch, "coverage", try coverageSummaryValue(scratch, set));
    try obj.put(scratch, "files", try coverageFilesValue(scratch, set));
    const value: std.json.Value = .{ .object = obj };
    return maybeWriteArtifact(a, allocator, scratch, args, "zig_coverage_baseline", value, argString(args, "output") orelse default_coverage_baseline, "coverage_baseline", &.{});
}

/// Executes the zig coverage budget check workflow and returns an allocator-owned structured result.
pub fn zigCoverageBudgetCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_coverage_budget_check", "coverage", null, null, true) catch |err| return evidenceInputError(a, allocator, "zig_coverage_budget_check", args, "coverage", err);
    defer input.deinit(allocator);
    var changed = changedPathList(allocator, a, argString(args, "changed_files"), toolTimeout(a, args)) catch std.ArrayList([]const u8).empty;
    defer {
        freeStringList(allocator, changed.items);
        changed.deinit(allocator);
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var budget = coverage_usecase.budget(allocator, .{
        .coverage = .{ .bytes = input.bytes, .source_kind = input.source_kind },
        .changed_files = changed.items,
        .min_line_rate_bp = @intCast(argInt(args, "min_line_rate_bp", 8000)),
        .min_changed_line_rate_bp = @intCast(argInt(args, "min_changed_line_rate_bp", 0)),
    }) catch |err| return performanceToolError(allocator, "zig_coverage_budget_check", "coverage_budget", err);
    defer budget.deinit(allocator);
    const value = coverageBudgetValue(arena.allocator(), a, budget) catch return error.OutOfMemory;
    return structured(allocator, value);
}

/// Executes the zig bench discover workflow and returns an allocator-owned structured result.
pub fn zigBenchDiscover(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = benchDiscoverValue(arena.allocator(), a, @intCast(@max(1, argInt(args, "limit", 50)))) catch |err| return performanceToolError(allocator, "zig_bench_discover", "scan_workspace", err);
    return structured(allocator, value);
}

/// Invokes zig bench run with caller-owned inputs; command and allocation failures propagate.
pub fn zigBenchRun(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const command_text = argString(args, "command") orelse return missingArgumentResult(allocator, "zig_bench_run", "command", "non-empty command string");
    const output = argString(args, "output") orelse ".zigars-cache/benchmarks/run.json";
    const apply = argBool(args, "apply", false);
    const timeout_ms = toolTimeout(a, args);
    const argv = splitToolArgs(allocator, command_text) catch |err| return splitToolArgsErrorResult(allocator, "zig_bench_run", "command", command_text, err);
    defer freeArgv(allocator, argv);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    if (!apply) {
        var obj = std.json.ObjectMap.empty;
        try putBase(scratch, &obj, a, "zig_bench_run", "Benchmark command preview", "medium", &.{
            "The benchmark command is not executed until apply=true.",
        });
        try obj.put(scratch, "command_argv", try argvValue(scratch, argv));
        try obj.put(scratch, "output", .{ .string = output });
        try obj.put(scratch, "applied", .{ .bool = false });
        try obj.put(scratch, "requires_apply", .{ .bool = true });
        try obj.put(scratch, "preimage_identity", preimageIdentityForPath(a, scratch, output) catch .null);
        return structured(allocator, .{ .object = obj });
    }
    const result = runCommand(allocator, a, argv, timeout_ms) catch |err| {
        const value = commandErrorValue(scratch, "benchmark command", argv, a.workspace.root, timeout_ms, err) catch return error.OutOfMemory;
        return structured(allocator, value);
    };
    defer result.deinit(allocator);
    var parsed = benchmark_model.parseText(allocator, result.stdout) catch BenchSet{};
    defer parsed.deinit(allocator);
    const value = benchRunArtifactValue(scratch, a, argv, timeout_ms, result, parsed) catch return error.OutOfMemory;
    const bytes = serializeAlloc(scratch, value) catch return error.OutOfMemory;
    const preimage_identity = preimageIdentityForPath(a, scratch, output) catch .null;
    writeAndRegisterArtifact(a, scratch, output, bytes, "zig_bench_run", "benchmark_run", argv, "caller_command", "", "", "benchmark run evidence") catch |err| return workspacePathErrorResult(a, allocator, "zig_bench_run", output, err);
    var obj = value.object;
    try obj.put(scratch, "artifact_identity", artifactIdentityValue(scratch, a, output, bytes) catch .null);
    try obj.put(scratch, "preimage_identity", preimage_identity);
    try obj.put(scratch, "output", .{ .string = output });
    try obj.put(scratch, "applied", .{ .bool = true });
    try obj.put(scratch, "requires_apply", .{ .bool = false });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig bench baseline workflow and returns an allocator-owned structured result.
pub fn zigBenchBaseline(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_bench_baseline", "results", null, null, true) catch |err| return evidenceInputError(a, allocator, "zig_bench_baseline", args, "results", err);
    defer input.deinit(allocator);
    var set = benchmark_usecase.parse(allocator, .{
        .bytes = input.bytes,
        .source_kind = input.source_kind,
    }) catch |err| return performanceToolError(allocator, "zig_bench_baseline", "parse_results", err);
    defer set.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, a, "zig_bench_baseline", "Benchmark baseline snapshot", "high", &.{
        "Baseline quality depends on stable machine state and benchmark determinism.",
    });
    try obj.put(scratch, "baseline_identity", .{ .string = argString(args, "baseline_id") orelse "workspace-current" });
    try obj.put(scratch, "benchmarks", try benchSamplesValue(scratch, set));
    try obj.put(scratch, "benchmark_count", .{ .integer = @intCast(set.samples.items.len) });
    return maybeWriteArtifact(a, allocator, scratch, args, "zig_bench_baseline", .{ .object = obj }, argString(args, "output") orelse default_bench_baseline, "benchmark_baseline", &.{});
}

/// Executes the zig benchmark history workflow and returns an allocator-owned structured result.
pub fn zigBenchmarkHistory(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const path = argString(args, "path") orelse default_bench_history;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, a, "zig_benchmark_history", "Benchmark history artifact read", "medium", &.{
        "History is caller-maintained; missing files are reported as empty history.",
    });
    try obj.put(scratch, "path", .{ .string = path });
    const bytes = a.workspace.readFileAlloc(a.io, path, max_evidence_bytes) catch |err| switch (err) {
        error.FileNotFound => {
            try obj.put(scratch, "history", try stringArrayValue(scratch, &.{}));
            try obj.put(scratch, "history_count", .{ .integer = 0 });
            try obj.put(scratch, "artifact_status", .{ .string = "missing" });
            return structured(allocator, .{ .object = obj });
        },
        else => return workspacePathErrorResult(a, allocator, "zig_benchmark_history", path, err),
    };
    defer allocator.free(bytes);
    const parsed = std.json.parseFromSlice(std.json.Value, scratch, bytes, .{}) catch null;
    if (parsed) |p| {
        try obj.put(scratch, "history", p.value);
        try obj.put(scratch, "history_count", .{ .integer = @intCast(jsonArrayLength(p.value)) });
    } else {
        try obj.put(scratch, "history", .{ .string = bytes });
        try obj.put(scratch, "history_count", .{ .integer = 1 });
    }
    try obj.put(scratch, "artifact_status", .{ .string = "present" });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig bench compare workflow and returns an allocator-owned structured result.
pub fn zigBenchCompare(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var current_input = readEvidenceInput(a, allocator, args, "zig_bench_compare", "current", null, null, true) catch |err| return evidenceInputError(a, allocator, "zig_bench_compare", args, "current", err);
    defer current_input.deinit(allocator);
    var baseline_input = readEvidenceInput(a, allocator, args, "zig_bench_compare", "baseline", null, null, true) catch |err| return evidenceInputError(a, allocator, "zig_bench_compare", args, "baseline", err);
    defer baseline_input.deinit(allocator);
    var comparison = benchmark_usecase.compare(allocator, .{
        .current = .{ .bytes = current_input.bytes, .source_kind = current_input.source_kind },
        .baseline = .{ .bytes = baseline_input.bytes, .source_kind = baseline_input.source_kind },
        .threshold_pct = @intCast(argInt(args, "threshold_pct", 5)),
    }) catch |err| return performanceToolError(allocator, "zig_bench_compare", "compare_benchmarks", err);
    defer comparison.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = benchCompareValue(arena.allocator(), a, comparison) catch return error.OutOfMemory;
    return structured(allocator, value);
}

/// Compares benchmark evidence against a regression threshold and optionally persists a one-shot gate session.
pub fn zigBenchRegressionGate(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var current_input = readEvidenceInput(a, allocator, args, "zig_bench_regression_gate", "current", null, null, true) catch |err| return evidenceInputError(a, allocator, "zig_bench_regression_gate", args, "current", err);
    defer current_input.deinit(allocator);
    var baseline_input = readEvidenceInput(a, allocator, args, "zig_bench_regression_gate", "baseline", null, null, true) catch |err| return evidenceInputError(a, allocator, "zig_bench_regression_gate", args, "baseline", err);
    defer baseline_input.deinit(allocator);
    var comparison = benchmark_usecase.compare(allocator, .{
        .current = .{ .bytes = current_input.bytes, .source_kind = current_input.source_kind },
        .baseline = .{ .bytes = baseline_input.bytes, .source_kind = baseline_input.source_kind },
        .threshold_pct = @intCast(argInt(args, "threshold_pct", 5)),
    }) catch |err| return performanceToolError(allocator, "zig_bench_regression_gate", "compare_benchmarks", err);
    defer comparison.deinit(allocator);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const apply = argBool(args, "apply", false);
    const now = unixMs(a);
    const session_id = if (argString(args, "session_id")) |id|
        id
    else
        try std.fmt.allocPrint(scratch, "bench-gate-{x}", .{std.hash.Wyhash.hash(0, current_input.bytes) ^ std.hash.Wyhash.hash(1, baseline_input.bytes)});
    const comparison_value = try benchCompareValue(scratch, a, comparison);

    var events = std.json.Array.init(scratch);
    try events.append(try sessions.eventValue(scratch, "evaluated", if (comparison.passed()) "benchmark regression gate passed" else "benchmark regression gate failed", now));
    var validation = std.json.ObjectMap.empty;
    try validation.put(scratch, "passed", .{ .bool = comparison.passed() });
    try validation.put(scratch, "threshold_pct", .{ .integer = comparison.threshold_pct });
    try validation.put(scratch, "compared_count", .{ .integer = @intCast(comparison.compared_count) });
    try validation.put(scratch, "regression_count", .{ .integer = @intCast(comparison.regressions.items.len) });
    try validation.put(scratch, "worst_regression_pct", .{ .float = comparison.worst_regression_pct });

    const envelope = try sessions.envelopeValue(scratch, .{
        .id = session_id,
        .kind = bench_gate_session_kind,
        .status = if (comparison.passed()) "completed" else "failed",
        .workspace_root = a.context.workspace.root,
        .created_at = now,
        .updated_at = now,
        .events = .{ .array = events },
        .validation = .{ .object = validation },
    });
    var obj = envelope.object;
    try obj.put(scratch, "tool", .{ .string = "zig_bench_regression_gate" });
    try obj.put(scratch, "comparison", comparison_value);
    try obj.put(scratch, "one_shot", .{ .bool = true });
    try obj.put(scratch, "resumable", .{ .bool = false });
    try obj.put(scratch, "applied", .{ .bool = apply });
    try obj.put(scratch, "requires_apply", .{ .bool = !apply });
    if (apply) {
        const path = sessions.appendSnapshot(scratch, a.context.workspace_store, bench_gate_session_kind, session_id, .{ .object = obj }, "performance.bench_regression_gate_session") catch |err| return workspacePathErrorResult(a, allocator, "zig_bench_regression_gate", sessions.session_root, err);
        try obj.put(scratch, "session_path", .{ .string = path });
    } else {
        try obj.put(scratch, "session_path", .{ .string = try sessions.sessionPath(scratch, bench_gate_session_kind, session_id) });
    }
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig perf budget check workflow and returns an allocator-owned structured result.
pub fn zigPerfBudgetCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const input_field = if (argString(args, "comparison") != null) "comparison" else if (argString(args, "results") != null) "results" else "comparison";
    var input = readEvidenceInput(a, allocator, args, "zig_perf_budget_check", input_field, null, null, false) catch |err| return evidenceInputError(a, allocator, "zig_perf_budget_check", args, input_field, err);
    defer input.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const max_regression_pct: f64 = @floatFromInt(argInt(args, "max_regression_pct", 5));
    const budget = benchmark_usecase.budget(scratch, .{
        .comparison = input.bytes,
        .max_regression_pct = max_regression_pct,
    }) catch benchmark_usecase.BudgetResult{
        .summary = .{ .regression_count = 0, .worst_regression_pct = 0 },
        .max_regression_pct = max_regression_pct,
    };
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, a, "zig_perf_budget_check", "Performance comparison budget check", "medium", &.{
        "Budget check is only as complete as the supplied benchmark comparison evidence.",
    });
    try obj.put(scratch, "max_regression_pct", .{ .float = max_regression_pct });
    try obj.put(scratch, "regression_count", .{ .integer = @intCast(budget.summary.regression_count) });
    try obj.put(scratch, "worst_regression_pct", .{ .float = budget.summary.worst_regression_pct });
    try obj.put(scratch, "passed", .{ .bool = budget.passed() });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig profile regression workflow and returns an allocator-owned structured result.
pub fn zigProfileRegression(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_profile_regression", "comparison", null, null, true) catch |err| return evidenceInputError(a, allocator, "zig_profile_regression", args, "comparison", err);
    defer input.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const backend = argString(args, "backend") orelse "samply";
    const plan = benchmark_usecase.planProfileRegression(scratch, .{
        .comparison = input.bytes,
        .backend = backend,
    }) catch benchmark_usecase.ProfileRegressionPlan{
        .summary = .{ .regression_count = 0, .worst_regression_pct = 0 },
        .backend = backend,
    };
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, a, "zig_profile_regression", "Regression-focused profiling plan", "medium", &.{
        "This tool plans profiling only; capture tools remain explicit and apply-gated.",
    });
    try obj.put(scratch, "backend", .{ .string = backend });
    try obj.put(scratch, "command", stringOrNull(argString(args, "command")));
    try obj.put(scratch, "regression_count", .{ .integer = @intCast(plan.summary.regression_count) });
    try obj.put(scratch, "needs_profile", .{ .bool = plan.needsProfile() });
    try obj.put(scratch, "recommended_tools", try stringArrayValue(scratch, plan.recommendedTools()));
    try obj.put(scratch, "stop_condition", .{ .string = "Capture a focused profile only for benchmarks whose comparison evidence still exceeds the configured regression threshold." });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig samply record workflow and returns an allocator-owned structured result.
pub fn zigSamplyRecord(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    if (a.context.platform.is_windows) return unsupportedBackendResult(a, allocator, "samply", "record", "Samply recording is not supported by zigars on this platform.");
    const command_text = argString(args, "command") orelse return missingArgumentResult(allocator, "zig_samply_record", "command", "non-empty command string");
    const samply_path = argString(args, "samply_path") orelse "samply";
    const output = argString(args, "output") orelse default_samply_profile;
    const apply = argBool(args, "apply", false);
    const command_argv = splitToolArgs(allocator, command_text) catch |err| return splitToolArgsErrorResult(allocator, "zig_samply_record", "command", command_text, err);
    defer freeArgv(allocator, command_argv);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const output_abs = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_samply_record", output, err);
    defer a.workspace.allocator.free(output_abs);
    const argv = try samplyRecordArgv(scratch, samply_path, output_abs, command_argv);
    if (!apply) return backendPreviewResult(a, allocator, scratch, "zig_samply_record", "samply", "record", argv, output, "Samply profile capture preview");
    const probe = checkBackend(a, scratch, "samply", &.{ samply_path, "--help" }, @min(toolTimeout(a, args), 5000));
    if (!probe.ok) return backendUnavailableResult(allocator, "samply", "record", samply_path, probe.status, "Install samply separately or pass samply_path to an existing executable; zigars never installs it.");
    ensureParentDir(a, output_abs) catch |err| return workspacePathErrorResult(a, allocator, "zig_samply_record", output, err);
    const run = runCommand(allocator, a, argv, toolTimeout(a, args)) catch |err| return backendErrorResult(allocator, "samply", "record", err, "Run the shown samply argv directly to inspect profiler-specific failures.");
    defer run.deinit(allocator);
    if (!run.succeeded()) return commandResultFailure(allocator, scratch, a, "zig_samply_record", argv, toolTimeout(a, args), run);
    return registerExistingArtifactResult(a, allocator, scratch, "zig_samply_record", output, "samply_profile", argv, "samply", "captured Samply profile", true);
}

/// Executes the zig samply summary workflow and returns an allocator-owned structured result.
pub fn zigSamplySummary(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_samply_summary", "profile", "path", "content", true) catch |err| return evidenceInputError(a, allocator, "zig_samply_summary", args, "profile", err);
    defer input.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = profileSummaryValue(arena.allocator(), a, "zig_samply_summary", input.bytes, "Samply or Firefox profile summary", @intCast(@max(1, argInt(args, "limit", 20)))) catch |err| return performanceToolError(allocator, "zig_samply_summary", "summarize_profile", err);
    return structured(allocator, value);
}

/// Executes the zig samply import workflow and returns an allocator-owned structured result.
pub fn zigSamplyImport(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_samply_import", "profile", "path", "content", true) catch |err| return evidenceInputError(a, allocator, "zig_samply_import", args, "profile", err);
    defer input.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = profileImportValue(scratch, a, input.bytes, input.source_kind) catch |err| return performanceToolError(allocator, "zig_samply_import", "import_profile", err);
    return maybeWriteArtifact(a, allocator, scratch, args, "zig_samply_import", value, argString(args, "output") orelse ".zigars-cache/profile/samply/imported.json", "samply_import", &.{});
}

/// Executes the zig samply artifact workflow and returns an allocator-owned structured result.
pub fn zigSamplyArtifact(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const path = argString(args, "path") orelse return missingArgumentResult(allocator, "zig_samply_artifact", "path", "workspace profile artifact path");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return registerExistingArtifactResult(a, allocator, arena.allocator(), "zig_samply_artifact", path, "samply_profile", &.{}, "samply", "registered Samply profile artifact", argBool(args, "apply", false));
}

/// Executes the zig profile open workflow and returns an allocator-owned structured result.
pub fn zigProfileOpen(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const path = argString(args, "path") orelse return missingArgumentResult(allocator, "zig_profile_open", "path", "workspace profile artifact path");
    const resolved = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_profile_open", path, err);
    defer a.workspace.allocator.free(resolved);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const abs_path = try scratch.dupe(u8, resolved);
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, a, "zig_profile_open", "Profile viewer launch plan", "high", &.{
        "zigars does not launch GUI viewers; the returned command is informational.",
    });
    try obj.put(scratch, "path", .{ .string = path });
    try obj.put(scratch, "abs_path", .{ .string = abs_path });
    try obj.put(scratch, "viewer", .{ .string = argString(args, "viewer") orelse "system default or profiler UI" });
    try obj.put(scratch, "launches_viewer", .{ .bool = false });
    try obj.put(scratch, "recommended_action", .{ .string = "Open the artifact with the selected profiler UI outside zigars." });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig tracy plan workflow and returns an allocator-owned structured result.
pub fn zigTracyPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = tracyPlanValue(arena.allocator(), a, @intCast(@max(1, argInt(args, "limit", 50)))) catch |err| return performanceToolError(allocator, "zig_tracy_plan", "scan_workspace", err);
    return structured(allocator, value);
}

/// Executes the zig tracy probe workflow and returns an allocator-owned structured result.
pub fn zigTracyProbe(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const tracy_path = argString(args, "tracy_capture_path") orelse "tracy-capture";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, a, "zig_tracy_probe", "Tracy capture backend probe", "high", &.{
        "Tracy is an optional external backend and is never installed by zigars.",
    });
    if (!argBool(args, "probe_backend", false)) {
        try obj.put(scratch, "backend_status", try backendStatusValue(scratch, "tracy-capture", false, "not_probed", "pass probe_backend=true to run tracy-capture --help", tracy_path));
        return structured(allocator, .{ .object = obj });
    }
    const probe = checkBackend(a, scratch, "tracy-capture", &.{ tracy_path, "--help" }, @min(toolTimeout(a, args), 5000));
    try obj.put(scratch, "backend_status", try backendStatusValue(scratch, "tracy-capture", probe.ok, probe.status, probe.resolution, tracy_path));
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig tracy capture workflow and returns an allocator-owned structured result.
pub fn zigTracyCapture(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    if (a.context.platform.is_windows) return unsupportedBackendResult(a, allocator, "tracy-capture", "capture", "Tracy capture is not supported by zigars on this platform.");
    const tracy_path = argString(args, "tracy_capture_path") orelse "tracy-capture";
    const output = argString(args, "output") orelse default_tracy_profile;
    const output_abs = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_tracy_capture", output, err);
    defer a.workspace.allocator.free(output_abs);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const argv = try tracyCaptureArgv(scratch, tracy_path, output_abs, argString(args, "address") orelse "127.0.0.1", @intCast(argInt(args, "port", 8086)), @intCast(argInt(args, "seconds", 5)));
    if (!argBool(args, "apply", false)) return backendPreviewResult(a, allocator, scratch, "zig_tracy_capture", "tracy-capture", "capture", argv, output, "Tracy capture preview");
    const probe = checkBackend(a, scratch, "tracy-capture", &.{ tracy_path, "--help" }, @min(toolTimeout(a, args), 5000));
    if (!probe.ok) return backendUnavailableResult(allocator, "tracy-capture", "capture", tracy_path, probe.status, "Install Tracy capture tooling separately or pass tracy_capture_path to an existing executable.");
    ensureParentDir(a, output_abs) catch |err| return workspacePathErrorResult(a, allocator, "zig_tracy_capture", output, err);
    const run = runCommand(allocator, a, argv, toolTimeout(a, args)) catch |err| return backendErrorResult(allocator, "tracy-capture", "capture", err, "Run the shown tracy-capture argv directly to inspect backend-specific failures.");
    defer run.deinit(allocator);
    if (!run.succeeded()) return commandResultFailure(allocator, scratch, a, "zig_tracy_capture", argv, toolTimeout(a, args), run);
    return registerExistingArtifactResult(a, allocator, scratch, "zig_tracy_capture", output, "tracy_capture", argv, "tracy-capture", "captured Tracy trace", true);
}

/// Executes the zig tracy artifacts workflow and returns an allocator-owned structured result.
pub fn zigTracyArtifacts(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const path = argString(args, "path") orelse return missingArgumentResult(allocator, "zig_tracy_artifacts", "path", "workspace Tracy artifact path");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return registerExistingArtifactResult(a, allocator, arena.allocator(), "zig_tracy_artifacts", path, "tracy_capture", &.{}, "tracy-capture", "registered Tracy trace artifact", argBool(args, "apply", false));
}

/// Executes the zig tracy hints workflow and returns an allocator-owned structured result.
pub fn zigTracyHints(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, a, "zig_tracy_hints", "Tracy instrumentation hints", "medium", &.{
        "Hints are advisory and do not modify source.",
    });
    var hints = std.json.Array.init(scratch);
    if (argString(args, "profile")) |profile| if (std.mem.indexOf(u8, profile, "hot") != null) try hints.append(try hintValue(scratch, "profile_hotspot", "Add a Tracy zone around the hottest function or loop identified by the profile."));
    if (argString(args, "bench")) |bench| if (std.mem.indexOf(u8, bench, "regression") != null) try hints.append(try hintValue(scratch, "benchmark_regression", "Place Tracy zones around the regressed benchmark setup, iteration body, and teardown paths."));
    if (hints.items.len == 0) {
        try hints.append(try hintValue(scratch, "entrypoints", "Instrument benchmark entrypoints before adding fine-grained zones."));
        try hints.append(try hintValue(scratch, "allocations", "Add counters around allocator-heavy paths when benchmark output suggests memory-driven variance."));
    }
    try obj.put(scratch, "hints", .{ .array = hints });
    try obj.put(scratch, "hint_count", .{ .integer = @intCast(hints.items.len) });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig perf evidence pack workflow and returns an allocator-owned structured result.
pub fn zigPerfEvidencePack(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, a, "zig_perf_evidence_pack", "Performance evidence bundle", "medium", &.{
        "Evidence pack stores supplied evidence and pointers; it does not run validation.",
    });
    var evidence = std.json.Array.init(scratch);
    try appendEvidencePointer(scratch, &evidence, "coverage", argString(args, "coverage"));
    try appendEvidencePointer(scratch, &evidence, "benchmarks", argString(args, "benchmarks"));
    try appendEvidencePointer(scratch, &evidence, "samply", argString(args, "samply"));
    try appendEvidencePointer(scratch, &evidence, "tracy", argString(args, "tracy"));
    try appendEvidencePointer(scratch, &evidence, "flamegraph", argString(args, "flamegraph"));
    try appendEvidencePointer(scratch, &evidence, "validation", argString(args, "validation"));
    try obj.put(scratch, "evidence", .{ .array = evidence });
    try obj.put(scratch, "evidence_count", .{ .integer = @intCast(evidence.items.len) });
    try obj.put(scratch, "ready_for_review", .{ .bool = evidence.items.len > 0 });
    return maybeWriteArtifact(a, allocator, scratch, args, "zig_perf_evidence_pack", .{ .object = obj }, argString(args, "output") orelse default_perf_evidence, "performance_evidence_pack", &.{});
}

/// Reads evidence input data from the provided context without taking ownership of inputs.
fn readEvidenceInput(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, primary: []const u8, path_field: ?[]const u8, content_field: ?[]const u8, required: bool) !Input {
    _ = allocator;
    _ = tool_name;
    if (content_field) |field| {
        if (argString(args, field)) |content| return .{ .bytes = content, .source_kind = field };
    }
    if (path_field) |field| {
        if (argString(args, field)) |path| {
            const bytes = try a.workspace.readFileAlloc(a.io, path, max_evidence_bytes);
            return .{ .bytes = bytes, .source_kind = "workspace_file", .path = path, .owned = bytes };
        }
    }
    if (argString(args, primary)) |value| {
        if (looksInlineEvidence(value)) return .{ .bytes = value, .source_kind = primary };
        const bytes = try a.workspace.readFileAlloc(a.io, value, max_evidence_bytes);
        return .{ .bytes = bytes, .source_kind = "workspace_file", .path = value, .owned = bytes };
    }
    if (!required) return .{ .bytes = "{}", .source_kind = "missing" };
    return error.MissingArgument;
}

/// Implements evidence input error workflow logic using caller-owned inputs.
fn evidenceInputError(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, field: []const u8, err: anyerror) !Result {
    if (err == error.MissingArgument) return missingArgumentResult(allocator, tool_name, field, "inline evidence content or workspace artifact path");
    const path = argString(args, field) orelse argString(args, "path") orelse field;
    return workspacePathErrorResult(a, allocator, tool_name, path, err);
}

/// Reports whether inline evidence matches the caller-provided data.
fn looksInlineEvidence(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return trimmed.len == 0 or trimmed[0] == '{' or trimmed[0] == '[' or std.mem.indexOfScalar(u8, trimmed, '\n') != null or std.mem.startsWith(u8, trimmed, "SF:") or containsAny(trimmed, &.{ " ns", " us", " ms", " s" });
}

/// Serializes coverage map fields into an allocator-owned JSON value; allocation failures propagate.
fn coverageMapValue(allocator: std.mem.Allocator, a: *App, kind: []const u8, set: CoverageSet, basis: []const u8, confidence: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, a, kind, basis, confidence, &.{
        "Line-rate coverage reflects supplied evidence only; branch and condition coverage are not inferred.",
    });
    try obj.put(allocator, "coverage", try coverageSummaryValue(allocator, set));
    try obj.put(allocator, "files", try coverageFilesValue(allocator, set));
    return .{ .object = obj };
}

/// Serializes coverage summary fields into an allocator-owned JSON value; allocation failures propagate.
fn coverageSummaryValue(allocator: std.mem.Allocator, set: CoverageSet) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "total_lines", .{ .integer = @intCast(set.total) });
    try obj.put(allocator, "covered_lines", .{ .integer = @intCast(set.covered) });
    try obj.put(allocator, "line_rate_bp", .{ .integer = @intCast(coverage_model.rateBp(set.covered, set.total)) });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(set.files.items.len) });
    try obj.put(allocator, "source_kind", .{ .string = set.source_kind });
    return .{ .object = obj };
}

/// Serializes coverage files fields into an allocator-owned JSON value; allocation failures propagate.
fn coverageFilesValue(allocator: std.mem.Allocator, set: CoverageSet) !std.json.Value {
    var files = std.json.Array.init(allocator);
    for (set.files.items) |file| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "path", .{ .string = file.path });
        try obj.put(allocator, "total_lines", .{ .integer = @intCast(file.total) });
        try obj.put(allocator, "covered_lines", .{ .integer = @intCast(file.covered) });
        try obj.put(allocator, "line_rate_bp", .{ .integer = @intCast(coverage_model.rateBp(file.covered, file.total)) });
        try files.append(.{ .object = obj });
    }
    return .{ .array = files };
}

/// Serializes coverage diff fields into an allocator-owned JSON value; allocation failures propagate.
fn coverageDiffValue(allocator: std.mem.Allocator, a: *App, diff: coverage_usecase.CoverageDiff) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, a, "zig_coverage_diff", "Coverage baseline comparison", "high", &.{
        "Only file paths present in supplied evidence can be compared.",
    });
    try obj.put(allocator, "current", try coverageSummaryValue(allocator, diff.current));
    try obj.put(allocator, "baseline", try coverageSummaryValue(allocator, diff.baseline));
    try obj.put(allocator, "line_rate_delta_bp", .{ .integer = diff.line_rate_delta_bp });
    var files = std.json.Array.init(allocator);
    for (diff.current.files.items) |file| {
        const before = coverage_model.findFile(diff.baseline, file.path) orelse continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "path", .{ .string = file.path });
        try item.put(allocator, "current_line_rate_bp", .{ .integer = @intCast(coverage_model.rateBp(file.covered, file.total)) });
        try item.put(allocator, "baseline_line_rate_bp", .{ .integer = @intCast(coverage_model.rateBp(before.covered, before.total)) });
        try item.put(allocator, "delta_bp", .{ .integer = @as(i64, @intCast(coverage_model.rateBp(file.covered, file.total))) - @as(i64, @intCast(coverage_model.rateBp(before.covered, before.total))) });
        try files.append(.{ .object = item });
    }
    try obj.put(allocator, "file_deltas", .{ .array = files });
    return .{ .object = obj };
}

/// Serializes coverage budget fields into an allocator-owned JSON value; allocation failures propagate.
fn coverageBudgetValue(allocator: std.mem.Allocator, a: *App, budget: coverage_usecase.CoverageBudget) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, a, "zig_coverage_budget_check", "Coverage budget check", "high", &.{
        "Changed-file coverage is computed only for changed paths present in supplied coverage evidence.",
    });
    try obj.put(allocator, "line_rate_bp", .{ .integer = @intCast(budget.line_rate_bp) });
    try obj.put(allocator, "min_line_rate_bp", .{ .integer = @intCast(budget.min_line_rate_bp) });
    try obj.put(allocator, "changed_line_rate_bp", .{ .integer = @intCast(budget.changed_line_rate_bp) });
    try obj.put(allocator, "min_changed_line_rate_bp", .{ .integer = @intCast(budget.min_changed_line_rate_bp) });
    try obj.put(allocator, "changed_file_count", .{ .integer = @intCast(budget.changed.count) });
    try obj.put(allocator, "passed", .{ .bool = budget.passed() });
    return .{ .object = obj };
}

/// Serializes bench samples fields into an allocator-owned JSON value; allocation failures propagate.
fn benchSamplesValue(allocator: std.mem.Allocator, set: BenchSet) !std.json.Value {
    var items = std.json.Array.init(allocator);
    for (set.samples.items) |sample| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "name", .{ .string = sample.name });
        try obj.put(allocator, "ns_per_iter", .{ .float = sample.ns_per_iter });
        try items.append(.{ .object = obj });
    }
    return .{ .array = items };
}

/// Serializes bench compare fields into an allocator-owned JSON value; allocation failures propagate.
fn benchCompareValue(allocator: std.mem.Allocator, a: *App, comparison: benchmark_model.BenchComparison) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, a, "zig_bench_compare", "Benchmark baseline comparison", "medium", &.{
        "Benchmark comparisons are sensitive to machine load, CPU governor, thermal state, and benchmark harness variance.",
    });
    try obj.put(allocator, "threshold_pct", .{ .integer = comparison.threshold_pct });
    try obj.put(allocator, "compared_count", .{ .integer = @intCast(comparison.compared_count) });
    try obj.put(allocator, "regressions", try benchDeltasValue(allocator, comparison.regressions.items));
    try obj.put(allocator, "regression_count", .{ .integer = @intCast(comparison.regressions.items.len) });
    try obj.put(allocator, "improvements", try benchDeltasValue(allocator, comparison.improvements.items));
    try obj.put(allocator, "improvement_count", .{ .integer = @intCast(comparison.improvements.items.len) });
    try obj.put(allocator, "worst_regression_pct", .{ .float = comparison.worst_regression_pct });
    try obj.put(allocator, "passed", .{ .bool = comparison.passed() });
    return .{ .object = obj };
}

/// Serializes bench deltas fields into an allocator-owned JSON value; allocation failures propagate.
fn benchDeltasValue(allocator: std.mem.Allocator, deltas: []benchmark_model.BenchDelta) !std.json.Value {
    var items = std.json.Array.init(allocator);
    for (deltas) |delta| {
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "name", .{ .string = delta.name });
        try obj.put(allocator, "baseline_ns_per_iter", .{ .float = delta.baseline_ns_per_iter });
        try obj.put(allocator, "current_ns_per_iter", .{ .float = delta.current_ns_per_iter });
        try obj.put(allocator, "delta_pct", .{ .float = delta.delta_pct });
        try items.append(.{ .object = obj });
    }
    return .{ .array = items };
}

/// Serializes bench run artifact fields into an allocator-owned JSON value; allocation failures propagate.
fn benchRunArtifactValue(allocator: std.mem.Allocator, a: *App, argv: []const []const u8, timeout_ms: i64, result: CommandRunResult, parsed: BenchSet) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, a, "zig_bench_run", "Executed caller-supplied benchmark command", "medium", &.{
        "Timing parser recognizes simple textual ns/us/ms/s lines; keep raw command output for audit.",
    });
    try obj.put(allocator, "command_argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "command_result", try commandResultValue(allocator, "benchmark command", argv, a.workspace.root, timeout_ms, result));
    try obj.put(allocator, "benchmarks", try benchSamplesValue(allocator, parsed));
    try obj.put(allocator, "benchmark_count", .{ .integer = @intCast(parsed.samples.items.len) });
    return .{ .object = obj };
}

/// Serializes bench discover fields into an allocator-owned JSON value; allocation failures propagate.
fn benchDiscoverValue(allocator: std.mem.Allocator, a: *App, limit: usize) !std.json.Value {
    var suites = std.json.Array.init(allocator);
    const scan = try a.workspace.scanDirectory(allocator, ".", null);
    defer scan.deinit(allocator);
    var seen: usize = 0;
    for (scan.entries) |entry| {
        if (seen >= limit) break;
        if (zig_analysis.skipWorkspacePath(entry.path)) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig") and std.mem.indexOf(u8, entry.path, "bench") == null) continue;
        const bytes = a.workspace.readFileAlloc(a.io, entry.path, 128 * 1024) catch continue;
        defer allocator.free(bytes);
        const lower = try asciiLowerAlloc(allocator, bytes);
        defer allocator.free(lower);
        if (!containsAny(lower, &.{ "benchmark", "zbench", "bench" })) continue;
        seen += 1;
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "path", .{ .string = try allocator.dupe(u8, entry.path) });
        try obj.put(allocator, "confidence", .{ .string = if (containsAny(lower, &.{"zbench"})) "high" else "medium" });
        try obj.put(allocator, "suggested_command", .{ .string = if (std.mem.eql(u8, entry.path, "build.zig")) "zig build bench" else "zig build bench" });
        try suites.append(.{ .object = obj });
    }
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, a, "zig_bench_discover", "Workspace benchmark discovery", "medium", &.{
        "Discovery is heuristic; projects may use custom build steps or external benchmark harnesses.",
    });
    try obj.put(allocator, "suites", .{ .array = suites });
    try obj.put(allocator, "suite_count", .{ .integer = @intCast(suites.items.len) });
    return .{ .object = obj };
}

/// Serializes coverage run artifact fields into an allocator-owned JSON value; allocation failures propagate.
fn coverageRunArtifactValue(allocator: std.mem.Allocator, a: *App, args: ?std.json.Value, command_result: std.json.Value) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, a, "zig_coverage_run_artifact", "Coverage command run evidence", "medium", &.{
        "Coverage artifacts named by the command are not parsed automatically by this run artifact.",
    });
    try obj.put(allocator, "target", stringOrNull(argString(args, "target")));
    try obj.put(allocator, "coverage_backend", .{ .string = argString(args, "coverage_backend") orelse "caller_command" });
    try obj.put(allocator, "coverage_artifacts", stringOrNull(argString(args, "coverage_artifacts")));
    try obj.put(allocator, "command_result", command_result);
    return .{ .object = obj };
}

/// Serializes profile summary fields into an allocator-owned JSON value; allocation failures propagate.
fn profileSummaryValue(allocator: std.mem.Allocator, a: *App, kind: []const u8, bytes: []const u8, basis: []const u8, limit: usize) !std.json.Value {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    var thread_names = std.json.Array.init(allocator);
    var sample_count: usize = 0;
    var frame_count: usize = 0;
    if (parsed.value == .object) {
        if (parsed.value.object.get("threads")) |threads| if (threads == .array) {
            for (threads.array.items[0..@min(limit, threads.array.items.len)]) |thread| {
                if (thread != .object) continue;
                if (stringField(thread.object, "name")) |name| try thread_names.append(.{ .string = try allocator.dupe(u8, name) });
                if (thread.object.get("samples")) |samples| sample_count += profileSamplesCount(samples);
                if (thread.object.get("frameTable")) |frames| frame_count += profileArrayLikeLength(frames);
            }
        };
    }
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, a, kind, basis, "medium", &.{
        "Profile summary extracts common Firefox/Samply JSON fields and does not symbolize native stacks.",
    });
    try obj.put(allocator, "thread_names", .{ .array = thread_names });
    try obj.put(allocator, "thread_count", .{ .integer = @intCast(thread_names.items.len) });
    try obj.put(allocator, "sample_count", .{ .integer = @intCast(sample_count) });
    try obj.put(allocator, "frame_count", .{ .integer = @intCast(frame_count) });
    try support.putSamplingUnavailable(allocator, &obj, "MCP sampling is not invoked by this deterministic Samply summary; raw profile counters are returned directly.");
    return .{ .object = obj };
}

/// Serializes profile import fields into an allocator-owned JSON value; allocation failures propagate.
fn profileImportValue(allocator: std.mem.Allocator, a: *App, bytes: []const u8, source_kind: []const u8) !std.json.Value {
    const summary = try profileSummaryValue(allocator, a, "zig_samply_import", bytes, "Imported profile evidence", 20);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const profile = try cloneValue(allocator, parsed.value);
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, a, "zig_samply_import", "Normalized imported profile artifact", "medium", &.{
        "Import preserves the source profile JSON and adds zigars summary metadata.",
    });
    try obj.put(allocator, "source_kind", .{ .string = source_kind });
    try obj.put(allocator, "summary", summary);
    try obj.put(allocator, "profile", profile);
    return .{ .object = obj };
}

/// Serializes tracy plan fields into an allocator-owned JSON value; allocation failures propagate.
fn tracyPlanValue(allocator: std.mem.Allocator, a: *App, limit: usize) !std.json.Value {
    var signals = std.json.Array.init(allocator);
    const scan = try a.workspace.scanDirectory(allocator, ".", null);
    defer scan.deinit(allocator);
    var seen: usize = 0;
    for (scan.entries) |entry| {
        if (seen >= limit) break;
        if (!std.mem.endsWith(u8, entry.path, ".zig") or zig_analysis.skipWorkspacePath(entry.path)) continue;
        const bytes = a.workspace.readFileAlloc(a.io, entry.path, 128 * 1024) catch continue;
        defer allocator.free(bytes);
        if (!containsAny(bytes, &.{ "Tracy", "tracy", "ZoneScoped", "TracyCZone", "TracyFrameMark", "enable_tracy" })) continue;
        seen += 1;
        var signal = std.json.ObjectMap.empty;
        try signal.put(allocator, "path", .{ .string = try allocator.dupe(u8, entry.path) });
        try signal.put(allocator, "line", .{ .integer = @intCast(firstSignalLine(bytes)) });
        try signals.append(.{ .object = signal });
    }
    var steps = std.json.Array.init(allocator);
    try steps.append(.{ .string = "Confirm the application is built with Tracy instrumentation enabled." });
    try steps.append(.{ .string = "Start the workload, then use zig_tracy_capture with an explicit tracy_capture_path when Tracy tooling is installed." });
    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, a, "zig_tracy_plan", "Tracy instrumentation and capture plan", "medium", &.{
        "Static detection is heuristic; build options and linked Tracy libraries may be project-specific.",
    });
    try obj.put(allocator, "signals", .{ .array = signals });
    try obj.put(allocator, "signal_count", .{ .integer = @intCast(signals.items.len) });
    try obj.put(allocator, "steps", .{ .array = steps });
    try obj.put(allocator, "instrumentation_status", .{ .string = if (signals.items.len > 0) "signals_found" else "no_static_signals" });
    return .{ .object = obj };
}

/// Implements maybe write artifact workflow logic using caller-owned inputs.
fn maybeWriteArtifact(a: *App, result_allocator: std.mem.Allocator, scratch: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, value: std.json.Value, output: []const u8, artifact_kind: []const u8, argv: []const []const u8) !Result {
    const bytes = serializeAlloc(scratch, value) catch return error.OutOfMemory;
    const apply = argBool(args, "apply", false);
    var obj = value.object;
    try obj.put(scratch, "output", .{ .string = output });
    try obj.put(scratch, "artifact_identity", artifactIdentityValue(scratch, a, output, bytes) catch .null);
    try obj.put(scratch, "preimage_identity", preimageIdentityForPath(a, scratch, output) catch .null);
    try obj.put(scratch, "applied", .{ .bool = apply });
    try obj.put(scratch, "requires_apply", .{ .bool = !apply });
    if (apply) {
        writeAndRegisterArtifact(a, scratch, output, bytes, tool_name, artifact_kind, argv, "", "", "", "performance workflow artifact") catch |err| return workspacePathErrorResult(a, result_allocator, tool_name, output, err);
    }
    return structured(result_allocator, .{ .object = obj });
}

/// Implements register existing artifact result workflow logic using caller-owned inputs.
fn registerExistingArtifactResult(a: *App, result_allocator: std.mem.Allocator, scratch: std.mem.Allocator, tool_name: []const u8, path: []const u8, artifact_kind: []const u8, argv: []const []const u8, backend: []const u8, notes: []const u8, apply: bool) !Result {
    const bytes = a.workspace.readFileAlloc(a.io, path, max_evidence_bytes) catch |err| return workspacePathErrorResult(a, result_allocator, tool_name, path, err);
    defer result_allocator.free(bytes);
    const resolved_abs = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, result_allocator, tool_name, path, err);
    defer a.workspace.allocator.free(resolved_abs);
    const abs_path = scratch.dupe(u8, resolved_abs) catch return error.OutOfMemory;
    const identity = artifacts.identityFromBytes(scratch, path, abs_path, bytes) catch return error.OutOfMemory;
    if (apply) {
        registerArtifact(a, scratch, .{
            .identity = identity,
            .provenance = .{
                .producer = tool_name,
                .artifact_kind = artifact_kind,
                .command_argv = argv,
                .backend_name = backend,
                .notes = notes,
                .toolchain = toolchainProvenance(a),
            },
            .indexed_at_unix_ms = unixMs(a),
        }) catch |err| return workspacePathErrorResult(a, result_allocator, tool_name, path, err);
    }
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, a, tool_name, "Profile artifact identity and registry handling", "high", &.{
        "Artifact registration records file identity and provenance; it does not validate profiler-specific semantics.",
    });
    try obj.put(scratch, "artifact_identity", artifacts.entryValue(scratch, .{ .identity = identity, .provenance = .{ .producer = tool_name, .artifact_kind = artifact_kind, .command_argv = argv, .backend_name = backend, .notes = notes, .toolchain = toolchainProvenance(a) }, .indexed_at_unix_ms = unixMs(a) }) catch .null);
    try obj.put(scratch, "applied", .{ .bool = apply });
    try obj.put(scratch, "requires_apply", .{ .bool = !apply });
    return structured(result_allocator, .{ .object = obj });
}

/// Writes and register artifact fields to the provided JSON stream and propagates writer failures.
fn writeAndRegisterArtifact(a: *App, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8, producer: []const u8, artifact_kind: []const u8, argv: []const []const u8, backend: []const u8, backend_version: []const u8, target: []const u8, notes: []const u8) !void {
    try a.workspace.putFile(path, bytes);
    const resolved_abs = try a.workspace.resolveOutput(path);
    defer a.workspace.allocator.free(resolved_abs);
    const abs_path = try allocator.dupe(u8, resolved_abs);
    const identity = try artifacts.identityFromBytes(allocator, path, abs_path, bytes);
    try registerArtifact(a, allocator, .{
        .identity = identity,
        .provenance = .{
            .producer = producer,
            .artifact_kind = artifact_kind,
            .command_argv = argv,
            .backend_name = backend,
            .backend_version = backend_version,
            .target = target,
            .notes = notes,
            .toolchain = toolchainProvenance(a),
        },
        .indexed_at_unix_ms = unixMs(a),
    });
}

/// Implements register artifact workflow logic using caller-owned inputs.
fn registerArtifact(a: *App, allocator: std.mem.Allocator, entry: artifacts.RegistryEntry) !void {
    try recordArtifact(a, allocator, entry);
}

/// Serializes artifact identity fields into an allocator-owned JSON value; allocation failures propagate.
fn artifactIdentityValue(allocator: std.mem.Allocator, a: *App, path: []const u8, bytes: []const u8) !std.json.Value {
    const resolved_abs = try a.workspace.resolveOutput(path);
    defer a.workspace.allocator.free(resolved_abs);
    const abs_path = try allocator.dupe(u8, resolved_abs);
    const identity = try artifacts.identityFromBytes(allocator, path, abs_path, bytes);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "abs_path", .{ .string = abs_path });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes.len) });
    try obj.put(allocator, "sha256", .{ .string = identity.sha256 });
    return .{ .object = obj };
}

/// Builds preimage identity metadata for the requested workspace path.
fn preimageIdentityForPath(a: *App, allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    const bytes = a.workspace.readFileAlloc(a.io, path, max_evidence_bytes) catch |err| switch (err) {
        error.FileNotFound => return preimageValue(allocator, false, 0, ""),
        else => return err,
    };
    defer allocator.free(bytes);
    const hash = try artifacts.sha256Hex(allocator, bytes);
    return preimageValue(allocator, true, bytes.len, hash);
}

/// Serializes preimage fields into an allocator-owned JSON value; allocation failures propagate.
fn preimageValue(allocator: std.mem.Allocator, exists: bool, bytes: usize, sha256: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exists", .{ .bool = exists });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(bytes) });
    try obj.put(allocator, "sha256", if (exists) .{ .string = sha256 } else .null);
    return .{ .object = obj };
}

/// Implements put base workflow logic using caller-owned inputs.
fn putBase(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, a: *App, kind: []const u8, evidence_basis: []const u8, confidence: []const u8, limitations: []const []const u8) !void {
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "evidence_basis", .{ .string = evidence_basis });
    try obj.put(allocator, "backend_status", try backendStatusValue(allocator, "not_required", true, "not_used", "No external backend is required for this operation.", ""));
    try obj.put(allocator, "command_argv", try argvValue(allocator, &.{}));
    try obj.put(allocator, "toolchain", try toolchainValue(allocator, a));
    try obj.put(allocator, "target", .null);
    try obj.put(allocator, "artifact_identity", .null);
    try obj.put(allocator, "baseline_identity", .null);
    try obj.put(allocator, "confidence", .{ .string = confidence });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, limitations));
    try obj.put(allocator, "skipped_validation", try stringArrayValue(allocator, &.{}));
}

/// Serializes backend status fields into an allocator-owned JSON value; allocation failures propagate.
fn backendStatusValue(allocator: std.mem.Allocator, backend: []const u8, ok: bool, status: []const u8, resolution: []const u8, configured_path: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "backend", .{ .string = backend });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "status", .{ .string = status });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    try obj.put(allocator, "configured_path", .{ .string = configured_path });
    return .{ .object = obj };
}

/// Serializes toolchain fields into an allocator-owned JSON value; allocation failures propagate.
fn toolchainValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "zig_path", .{ .string = a.config.zig_path });
    try obj.put(allocator, "zls_path", .{ .string = a.config.zls_path });
    try obj.put(allocator, "zflame_path", .{ .string = a.config.zflame_path });
    try obj.put(allocator, "diff_folded_path", .{ .string = a.config.diff_folded_path });
    return .{ .object = obj };
}

/// Implements toolchain provenance workflow logic using caller-owned inputs.
fn toolchainProvenance(a: *App) artifacts.Toolchain {
    return .{
        .zig_path = a.config.zig_path,
        .zls_path = a.config.zls_path,
        .zflame_path = a.config.zflame_path,
        .diff_folded_path = a.config.diff_folded_path,
    };
}

/// Serializes string array fields into an allocator-owned JSON value; allocation failures propagate.
fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

/// Extracts string or null data from JSON input without taking ownership of borrowed values.
fn stringOrNull(value: ?[]const u8) std.json.Value {
    return if (value) |text| .{ .string = text } else .null;
}

/// Implements int field workflow logic using caller-owned inputs.
fn intField(obj: std.json.ObjectMap, name: []const u8) ?i64 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |i| i,
        .float => |f| floatToInt(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

fn floatToInt(value: f64) ?i64 {
    if (!std.math.isFinite(value)) return null;
    const max: f64 = @floatFromInt(std.math.maxInt(i64));
    const min: f64 = @floatFromInt(std.math.minInt(i64));
    if (value >= max or value < min) return null;
    return @intFromFloat(value);
}

/// Implements float field workflow logic using caller-owned inputs.
fn floatField(obj: std.json.ObjectMap, name: []const u8) ?f64 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Extracts string field data from JSON input without taking ownership of borrowed values.
fn stringField(obj: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = obj.get(name) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

/// Implements elapsed ms workflow logic using caller-owned inputs.
fn elapsedMs(io: std.Io, started_ns: anytype) i64 {
    const duration_ns = std.Io.Clock.now(.real, io).nanoseconds - started_ns;
    if (duration_ns <= 0) return 0;
    return @intCast(@divTrunc(duration_ns, std.time.ns_per_ms));
}

/// Releases argv allocations; callers must not reuse freed items.
fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

/// Extracts json array length data from JSON input without taking ownership of borrowed values.
fn jsonArrayLength(value: std.json.Value) usize {
    return switch (value) {
        .array => |array| array.items.len,
        else => 0,
    };
}

/// Implements profile samples count workflow logic using caller-owned inputs.
fn profileSamplesCount(value: std.json.Value) usize {
    if (value == .object) {
        if (value.object.get("data")) |data| return profileArrayLikeLength(data);
    }
    return profileArrayLikeLength(value);
}

/// Implements profile array like length workflow logic using caller-owned inputs.
fn profileArrayLikeLength(value: std.json.Value) usize {
    return switch (value) {
        .array => |array| array.items.len,
        .object => |obj| if (obj.get("length")) |len| @intCast(@max(0, switch (len) {
            .integer => |i| i,
            else => 0,
        })) else 0,
        else => 0,
    };
}

/// Implements first signal line workflow logic using caller-owned inputs.
fn firstSignalLine(bytes: []const u8) usize {
    var line: usize = 1;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |text| : (line += 1) {
        if (containsAny(text, &.{ "Tracy", "tracy", "ZoneScoped", "TracyCZone", "TracyFrameMark", "enable_tracy" })) return line;
    }
    return 1;
}

/// Reports whether any matches the caller-provided data.
fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    return false;
}

/// Implements ascii lower alloc workflow logic using caller-owned inputs.
fn asciiLowerAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, input);
    for (out) |*ch| ch.* = std.ascii.toLower(ch.*);
    return out;
}

/// Appends evidence pointer data into caller-provided storage, propagating allocation failures.
fn appendEvidencePointer(allocator: std.mem.Allocator, evidence: *std.json.Array, name: []const u8, value: ?[]const u8) !void {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "name", .{ .string = name });
    try obj.put(allocator, "provided", .{ .bool = value != null });
    try obj.put(allocator, "value", stringOrNull(value));
    try evidence.append(.{ .object = obj });
}

/// Serializes hint fields into an allocator-owned JSON value; allocation failures propagate.
fn hintValue(allocator: std.mem.Allocator, kind: []const u8, text: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "text", .{ .string = text });
    return .{ .object = obj };
}

/// Implements samply record argv workflow logic using caller-owned inputs.
fn samplyRecordArgv(allocator: std.mem.Allocator, samply_path: []const u8, output_abs: []const u8, command_argv: []const []const u8) ![]const []const u8 {
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(allocator, &.{ samply_path, "record", "-o", output_abs, "--" });
    try argv.appendSlice(allocator, command_argv);
    return argv.toOwnedSlice(allocator);
}

/// Implements tracy capture argv workflow logic using caller-owned inputs.
fn tracyCaptureArgv(allocator: std.mem.Allocator, tracy_path: []const u8, output_abs: []const u8, address: []const u8, port: i64, seconds: i64) ![]const []const u8 {
    const port_text = try std.fmt.allocPrint(allocator, "{d}", .{port});
    const seconds_text = try std.fmt.allocPrint(allocator, "{d}", .{seconds});
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(allocator, &.{ tracy_path, "-o", output_abs, "-a", address, "-p", port_text, "-s", seconds_text });
    return argv.toOwnedSlice(allocator);
}

/// Implements backend preview result workflow logic using caller-owned inputs.
fn backendPreviewResult(a: *App, result_allocator: std.mem.Allocator, scratch: std.mem.Allocator, tool_name: []const u8, backend: []const u8, operation: []const u8, argv: []const []const u8, output: []const u8, basis: []const u8) !Result {
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, a, tool_name, basis, "medium", &.{
        "The external backend is not executed until apply=true.",
    });
    try obj.put(scratch, "backend_status", try backendStatusValue(scratch, backend, false, "not_probed", "Preview mode does not probe or execute the backend.", argv[0]));
    try obj.put(scratch, "operation", .{ .string = operation });
    try obj.put(scratch, "command_argv", try argvValue(scratch, argv));
    try obj.put(scratch, "output", .{ .string = output });
    try obj.put(scratch, "preimage_identity", preimageIdentityForPath(a, scratch, output) catch .null);
    try obj.put(scratch, "applied", .{ .bool = false });
    try obj.put(scratch, "requires_apply", .{ .bool = true });
    return structured(result_allocator, .{ .object = obj });
}

/// Implements ensure parent dir workflow logic using caller-owned inputs.
fn ensureParentDir(a: *App, abs_path: []const u8) !void {
    try a.workspace.ensureParentForAbsoluteOutput(abs_path);
}

/// Implements command result failure workflow logic using caller-owned inputs.
fn commandResultFailure(result_allocator: std.mem.Allocator, scratch: std.mem.Allocator, a: *App, tool_name: []const u8, argv: []const []const u8, timeout_ms: i64, run: CommandRunResult) !Result {
    var obj = std.json.ObjectMap.empty;
    try putBase(scratch, &obj, a, tool_name, "External backend command failed", "high", &.{
        "Inspect stdout and stderr from the backend command before trusting any partial artifact.",
    });
    try obj.put(scratch, "ok", .{ .bool = false });
    try obj.put(scratch, "command_result", try commandResultValue(scratch, tool_name, argv, a.workspace.root, timeout_ms, run));
    return structured(result_allocator, .{ .object = obj });
}

/// Implements unsupported backend result workflow logic using caller-owned inputs.
fn unsupportedBackendResult(a: *App, allocator: std.mem.Allocator, backend: []const u8, operation: []const u8, resolution: []const u8) !Result {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = "UnsupportedPlatform" });
    try obj.put(allocator, "error_kind", .{ .string = "unsupported_platform" });
    try obj.put(allocator, "platform", .{ .string = a.context.platform.os });
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return structured(allocator, .{ .object = obj });
}

/// Implements performance tool error workflow logic using caller-owned inputs.
fn performanceToolError(allocator: std.mem.Allocator, tool_name: []const u8, operation: []const u8, err: anyerror) !Result {
    return toolErrorFromError(allocator, .{
        .tool = tool_name,
        .operation = operation,
        .phase = "performance_workflow",
        .code = "performance_evidence_failed",
        .category = "analysis",
        .resolution = "Provide readable LCOV, zigars coverage JSON, benchmark JSON, or simple textual benchmark timing evidence and retry.",
    }, err);
}

const fakes = @import("../../../testing/fakes/root.zig");

/// Returns a typed context backed by this fixture or runtime state.
fn performanceTestContext(
    command_runner: *fakes.FakeCommandRunner,
    workspace_store: *fakes.FakeWorkspaceStore,
    workspace_scanner: *fakes.FakeWorkspaceScanner,
    backend_probe: ?*fakes.FakeBackendProbe,
    artifact_store: ?*fakes.FakeArtifactStore,
    platform: app_context.PlatformView,
) app_context.PerformanceContext {
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigars-cache" },
        .tool_paths = .{ .zig = "zig", .zls = "zls", .zflame = "zflame", .diff_folded = "diff-folded" },
        .timeouts = .{ .command_ms = 1000, .zls_ms = 1000 },
        .platform = platform,
        .command_runner = command_runner.port(),
        .workspace_store = workspace_store.port(),
        .workspace_scanner = workspace_scanner.port(),
        .backend_probe = if (backend_probe) |probe| probe.port() else null,
        .artifact_store = if (artifact_store) |store| store.port() else null,
    };
}

/// Parses argument input using caller-provided storage; malformed input and allocation failures propagate.
fn parsedArgs(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, text, .{});
}

/// Implements command request workflow logic using caller-owned inputs.
fn commandRequest(argv: []const []const u8, timeout_ms: u64) ports.CommandRequest {
    return .{
        .argv = argv,
        .cwd = "/repo",
        .timeout_ms = timeout_ms,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    };
}

/// Builds preimage identity metadata for the requested workspace path.
fn expectMissingPreimage(workspace: *fakes.FakeWorkspaceStore, path: []const u8) !void {
    try workspace.expectReadError(.{
        .path = path,
        .max_bytes = max_evidence_bytes,
        .provenance = "arch110-workflow-read",
    }, error.FileNotFound);
}

/// Implements expect resolve output workflow logic using caller-owned inputs.
fn expectResolveOutput(workspace: *fakes.FakeWorkspaceStore, path: []const u8, abs_path: []const u8) !void {
    try workspace.expectResolve(.{
        .path = path,
        .for_output = true,
        .provenance = "arch110-workflow-resolve-output",
    }, abs_path);
}

/// Implements expect resolve input workflow logic using caller-owned inputs.
fn expectResolveInput(workspace: *fakes.FakeWorkspaceStore, path: []const u8, abs_path: []const u8) !void {
    try workspace.expectResolve(.{
        .path = path,
        .provenance = "arch110-workflow-resolve",
    }, abs_path);
}

/// Implements expect artifact record workflow logic using caller-owned inputs.
fn expectArtifactRecord(
    allocator: std.mem.Allocator,
    store: *fakes.FakeArtifactStore,
    path: []const u8,
    producer: []const u8,
    artifact_kind: []const u8,
    argv: []const []const u8,
    backend: []const u8,
    backend_version: []const u8,
    target: []const u8,
    notes: []const u8,
) !void {
    const abs_path = try std.fmt.allocPrint(allocator, "/repo/{s}", .{path});
    try store.expectRecordWorkspace(.{
        .path = path,
        .producer = producer,
        .artifact_kind = artifact_kind,
        .command_argv = argv,
        .backend_name = backend,
        .backend_version = backend_version,
        .target = target,
        .notes = notes,
        .toolchain = .{
            .zig_path = "zig",
            .zls_path = "zls",
            .zflame_path = "zflame",
            .diff_folded_path = "diff-folded",
        },
        .indexed_at_unix_ms = 0,
    }, .{
        .path = path,
        .abs_path = abs_path,
        .bytes = 0,
        .sha256 = "sha256",
        .indexed_at_unix_ms = 0,
    });
}

test "performance command workflows execute and register coverage and benchmark artifacts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var artifacts_fake = fakes.FakeArtifactStore.init(std.testing.allocator);
    defer artifacts_fake.deinit();

    const context = performanceTestContext(&commands, &workspace, &scanner, null, &artifacts_fake, .{});
    var app = App.init(context, allocator);

    var coverage_args = try parsedArgs(allocator,
        \\{"command":"zig test --coverage","output":"coverage/run.json","target":"native","coverage_backend":"kcov","coverage_artifacts":"kcov-out","apply":true}
    );
    defer coverage_args.deinit();
    const coverage_argv = &.{ "zig", "test", "--coverage" };
    const coverage_run = CommandRunResult{
        .term = .{ .exited = 0 },
        .stdout = "coverage ok\n",
        .stderr = "",
        .duration_ms = 12,
    };
    const coverage_command_value = try commandResultValue(allocator, "coverage command", coverage_argv, "/repo", 1000, coverage_run);
    const coverage_artifact_value = try coverageRunArtifactValue(allocator, &app, coverage_args.value, coverage_command_value);
    const coverage_bytes = try serializeAlloc(allocator, coverage_artifact_value);

    try commands.expectRun(commandRequest(coverage_argv, 1000), .{
        .exit_code = 0,
        .stdout = "coverage ok\n",
        .stderr = "",
        .duration_ms = 12,
    });
    try expectMissingPreimage(&workspace, "coverage/run.json");
    try workspace.expectWrite(.{
        .path = "coverage/run.json",
        .bytes = coverage_bytes,
        .create_parent_dirs = true,
        .replace_existing = true,
        .provenance = "arch110-workflow-write",
    }, .{ .bytes_written = coverage_bytes.len });
    try expectResolveOutput(&workspace, "coverage/run.json", "/repo/coverage/run.json");
    try expectArtifactRecord(allocator, &artifacts_fake, "coverage/run.json", "zig_coverage_run", "coverage_run", coverage_argv, "kcov", "", "native", "coverage run evidence");
    try expectResolveOutput(&workspace, "coverage/run.json", "/repo/coverage/run.json");

    const coverage_result = try zigCoverageRun(&app, allocator, coverage_args.value);
    try std.testing.expect(!coverage_result.is_error);
    try std.testing.expect(coverage_result.value.object.get("applied").?.bool);

    var bench_args = try parsedArgs(allocator,
        \\{"command":"zig build bench","output":"bench/run.json","apply":true}
    );
    defer bench_args.deinit();
    const bench_argv = &.{ "zig", "build", "bench" };
    const bench_run = CommandRunResult{
        .term = .{ .exited = 0 },
        .stdout = "parseJson 25 ns\nrender 1.5 ms\n",
        .stderr = "",
        .duration_ms = 31,
    };
    const parsed = try benchmark_model.parseText(allocator, bench_run.stdout);
    const bench_value = try benchRunArtifactValue(allocator, &app, bench_argv, 1000, bench_run, parsed);
    const bench_bytes = try serializeAlloc(allocator, bench_value);

    try commands.expectRun(commandRequest(bench_argv, 1000), .{
        .exit_code = 0,
        .stdout = bench_run.stdout,
        .stderr = "",
        .duration_ms = 31,
    });
    try expectMissingPreimage(&workspace, "bench/run.json");
    try workspace.expectWrite(.{
        .path = "bench/run.json",
        .bytes = bench_bytes,
        .create_parent_dirs = true,
        .replace_existing = true,
        .provenance = "arch110-workflow-write",
    }, .{ .bytes_written = bench_bytes.len });
    try expectResolveOutput(&workspace, "bench/run.json", "/repo/bench/run.json");
    try expectArtifactRecord(allocator, &artifacts_fake, "bench/run.json", "zig_bench_run", "benchmark_run", bench_argv, "caller_command", "", "", "benchmark run evidence");
    try expectResolveOutput(&workspace, "bench/run.json", "/repo/bench/run.json");

    const bench_result = try zigBenchRun(&app, allocator, bench_args.value);
    try std.testing.expect(!bench_result.is_error);
    try std.testing.expectEqual(@as(i64, 2), bench_result.value.object.get("benchmark_count").?.integer);

    try commands.verify();
    try workspace.verify();
    try scanner.verify();
    try artifacts_fake.verify();
}

test "bench regression gate is preview-only unless apply is set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();

    const context = performanceTestContext(&commands, &workspace, &scanner, null, null, .{});
    var app = App.init(context, allocator);
    var args = try parsedArgs(allocator,
        \\{"current":"parse 120 ns\n","baseline":"parse 100 ns\n","threshold_pct":5,"session_id":"gate-1","apply":false}
    );
    defer args.deinit();

    const result = try zigBenchRegressionGate(&app, allocator, args.value);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("zig_bench_regression_gate", result.value.object.get("tool").?.string);
    try std.testing.expectEqualStrings("failed", result.value.object.get("status").?.string);
    try std.testing.expect(!result.value.object.get("applied").?.bool);
    try std.testing.expect(result.value.object.get("requires_apply").?.bool);
    try std.testing.expectEqualStrings(".zigars-cache/sessions/bench_regression_gate/gate-1.jsonl", result.value.object.get("session_path").?.string);
    try workspace.verify();
    try commands.verify();
}

test "performance workflows report command errors and parse workspace evidence variants" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    const context = performanceTestContext(&commands, &workspace, &scanner, null, null, .{});
    var app = App.init(context, allocator);

    var error_args = try parsedArgs(allocator,
        \\{"command":"zig test","apply":true}
    );
    defer error_args.deinit();
    try commands.expectRunError(commandRequest(&.{ "zig", "test" }, 1000), error.Timeout);
    const command_error = try zigCoverageRun(&app, allocator, error_args.value);
    try std.testing.expect(!command_error.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("command_error", command_error.value.object.get("kind").?.string);

    var bench_error_args = try parsedArgs(allocator,
        \\{"command":"zig bench","apply":true}
    );
    defer bench_error_args.deinit();
    try commands.expectRunError(commandRequest(&.{ "zig", "bench" }, 1000), error.Unavailable);
    const bench_error = try zigBenchRun(&app, allocator, bench_error_args.value);
    try std.testing.expect(!bench_error.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("command_error", bench_error.value.object.get("kind").?.string);

    var history_args = try parsedArgs(allocator,
        \\{"path":"bench/history.json"}
    );
    defer history_args.deinit();
    try workspace.expectRead(.{ .path = "bench/history.json", .max_bytes = max_evidence_bytes, .provenance = "arch110-workflow-read" }, "[{\"name\":\"render\"}]");
    const history = try zigBenchmarkHistory(&app, allocator, history_args.value);
    try std.testing.expectEqual(@as(i64, 1), history.value.object.get("history_count").?.integer);

    var text_history_args = try parsedArgs(allocator,
        \\{"path":"bench/history.txt"}
    );
    defer text_history_args.deinit();
    try workspace.expectRead(.{ .path = "bench/history.txt", .max_bytes = max_evidence_bytes, .provenance = "arch110-workflow-read" }, "render 25 ns\n");
    const text_history = try zigBenchmarkHistory(&app, allocator, text_history_args.value);
    try std.testing.expectEqual(@as(i64, 1), text_history.value.object.get("history_count").?.integer);

    var path_args = try parsedArgs(allocator,
        \\{"path":"coverage/lcov.info","format":"lcov"}
    );
    defer path_args.deinit();
    try workspace.expectRead(.{ .path = "coverage/lcov.info", .max_bytes = max_evidence_bytes, .provenance = "arch110-workflow-read" },
        \\SF:src/main.zig
        \\DA:1,1
        \\DA:2,0
        \\end_of_record
        \\
    );
    const mapped = try zigCoverageMap(&app, allocator, path_args.value);
    try std.testing.expectEqual(@as(i64, 2), mapped.value.object.get("coverage").?.object.get("total_lines").?.integer);

    var primary_path_args = try parsedArgs(allocator,
        \\{"coverage":"coverage/current.info"}
    );
    defer primary_path_args.deinit();
    try workspace.expectRead(.{ .path = "coverage/current.info", .max_bytes = max_evidence_bytes, .provenance = "arch110-workflow-read" },
        \\SF:src/main.zig
        \\DA:1,1
        \\end_of_record
        \\
    );
    const budget_from_path = try zigCoverageBudgetCheck(&app, allocator, primary_path_args.value);
    try std.testing.expect(budget_from_path.value.object.get("passed").?.bool);

    const missing_evidence = try zigCoverageMap(&app, allocator, null);
    try std.testing.expect(missing_evidence.is_error);
    try std.testing.expectEqualStrings("missing_required_argument", missing_evidence.value.object.get("code").?.string);

    var denied_path_args = try parsedArgs(allocator,
        \\{"path":"coverage/denied.info"}
    );
    defer denied_path_args.deinit();
    try workspace.expectReadError(.{ .path = "coverage/denied.info", .max_bytes = max_evidence_bytes, .provenance = "arch110-workflow-read" }, error.AccessDenied);
    const denied_evidence = try zigCoverageMap(&app, allocator, denied_path_args.value);
    try std.testing.expect(denied_evidence.is_error);
    try std.testing.expectEqualStrings("workspace_path_error", denied_evidence.value.object.get("kind").?.string);

    const missing_budget = try zigPerfBudgetCheck(&app, allocator, null);
    try std.testing.expect(missing_budget.value.object.get("passed").?.bool);

    var invalid_profile_args = try parsedArgs(allocator,
        \\{"content":"not json"}
    );
    defer invalid_profile_args.deinit();
    const invalid_profile = try zigSamplySummary(&app, allocator, invalid_profile_args.value);
    try std.testing.expect(invalid_profile.is_error);
    try std.testing.expectEqualStrings("tool_error", invalid_profile.value.object.get("kind").?.string);

    try commands.verify();
    try workspace.verify();
    try scanner.verify();
}

test "performance scanner and profile helpers cover discovery summaries and private edges" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    const context = performanceTestContext(&commands, &workspace, &scanner, null, null, .{});
    var app = App.init(context, allocator);

    try workspace.expectScanDirectory(.{ .path = ".", .provenance = "arch110-workflow-scan" }, &.{
        "build.zig",
        "src/main.zig",
        ".zig-cache/generated.zig",
        "README.md",
    });
    try workspace.expectRead(.{ .path = "build.zig", .max_bytes = 128 * 1024, .provenance = "arch110-workflow-read" }, "const zbench = @import(\"zbench\");\n");
    try workspace.expectRead(.{ .path = "src/main.zig", .max_bytes = 128 * 1024, .provenance = "arch110-workflow-read" }, "pub fn main() void {}\n");
    var discover_args = try parsedArgs(allocator, "{\"limit\":3}");
    defer discover_args.deinit();
    const discovered = try zigBenchDiscover(&app, allocator, discover_args.value);
    try std.testing.expectEqual(@as(i64, 1), discovered.value.object.get("suite_count").?.integer);

    try workspace.expectScanDirectory(.{ .path = ".", .provenance = "arch110-workflow-scan" }, &.{
        "src/tracy.zig",
        "src/plain.zig",
    });
    try workspace.expectRead(.{ .path = "src/tracy.zig", .max_bytes = 128 * 1024, .provenance = "arch110-workflow-read" }, "pub fn work() void {\n    TracyCZone();\n}\n");
    try workspace.expectRead(.{ .path = "src/plain.zig", .max_bytes = 128 * 1024, .provenance = "arch110-workflow-read" }, "pub fn plain() void {}\n");
    const tracy_plan = try zigTracyPlan(&app, allocator, discover_args.value);
    try std.testing.expectEqual(@as(i64, 1), tracy_plan.value.object.get("signal_count").?.integer);

    const profile_json =
        \\{"threads":[{"name":"main","samples":{"data":[1,2,3]},"frameTable":{"length":4}},{"samples":[1]}]}
    ;
    var summary_args = try parsedArgs(allocator,
        \\{"content":"{\"threads\":[{\"name\":\"main\",\"samples\":{\"data\":[1,2,3]},\"frameTable\":{\"length\":4}},{\"samples\":[1]}]}","limit":2}
    );
    defer summary_args.deinit();
    const summary = try zigSamplySummary(&app, allocator, summary_args.value);
    try std.testing.expectEqual(@as(i64, 4), summary.value.object.get("sample_count").?.integer);

    const parsed_profile = try std.json.parseFromSlice(std.json.Value, allocator, profile_json, .{});
    defer parsed_profile.deinit();
    try std.testing.expectEqual(@as(usize, 3), profileSamplesCount(parsed_profile.value.object.get("threads").?.array.items[0].object.get("samples").?));
    try std.testing.expectEqual(@as(usize, 0), jsonArrayLength(parsed_profile.value.object.get("threads").?.array.items[0]));
    try std.testing.expectEqual(@as(usize, 2), firstSignalLine("nope\nTracyFrameMark();\n"));
    try std.testing.expectEqual(@as(usize, 1), firstSignalLine("no signals\n"));
    try std.testing.expectEqual(@as(?i64, 7), intField(parsed_profile.value.object, "missing") orelse 7);
    try std.testing.expectEqual(@as(?f64, 2.5), floatField(parsed_profile.value.object, "missing") orelse 2.5);
    try std.testing.expectEqual(@as(?[]const u8, null), stringField(parsed_profile.value.object, "missing"));
    var numbers = std.json.ObjectMap.empty;
    try numbers.put(allocator, "int_float", .{ .float = 9.75 });
    try numbers.put(allocator, "huge_float", .{ .float = 1e308 });
    try numbers.put(allocator, "nan_float", .{ .float = std.math.nan(f64) });
    try numbers.put(allocator, "int_text", .{ .number_string = "42" });
    try numbers.put(allocator, "float_int", .{ .integer = 5 });
    try numbers.put(allocator, "float_text", .{ .number_string = "2.5" });
    try numbers.put(allocator, "bad_text", .{ .number_string = "nan?" });
    try std.testing.expectEqual(@as(?i64, 9), intField(numbers, "int_float"));
    try std.testing.expectEqual(@as(?i64, null), intField(numbers, "huge_float"));
    try std.testing.expectEqual(@as(?i64, null), intField(numbers, "nan_float"));
    try std.testing.expectEqual(@as(?i64, 42), intField(numbers, "int_text"));
    try std.testing.expectEqual(@as(?i64, null), intField(numbers, "bad_text"));
    try std.testing.expectEqual(@as(?f64, 5.0), floatField(numbers, "float_int"));
    try std.testing.expectEqual(@as(?f64, 2.5), floatField(numbers, "float_text"));
    try std.testing.expectEqual(@as(?f64, null), floatField(numbers, "bad_text"));
    try std.testing.expect(containsAny("abc ms", &.{" ms"}));
    const lowered = try asciiLowerAlloc(allocator, "BenchMARK");
    try std.testing.expectEqualStrings("benchmark", lowered);

    try commands.verify();
    try workspace.verify();
    try scanner.verify();
}

test "performance backend workflows cover preview unavailable failed and successful captures" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var probe = fakes.FakeBackendProbe.init(std.testing.allocator);
    defer probe.deinit();
    var artifacts_fake = fakes.FakeArtifactStore.init(std.testing.allocator);
    defer artifacts_fake.deinit();
    const context = performanceTestContext(&commands, &workspace, &scanner, &probe, &artifacts_fake, .{ .os = "linux", .arch = "x86_64", .is_linux = true });
    var app = App.init(context, allocator);

    var tracy_probe_args = try parsedArgs(allocator,
        \\{"probe_backend":true,"tracy_capture_path":"tracy-custom"}
    );
    defer tracy_probe_args.deinit();
    try probe.expectCheck(.{ .backend = "tracy-capture", .argv = &.{ "tracy-custom", "--help" }, .cwd = "/repo", .timeout_ms = 1000, .provenance = "arch110-workflow-backend-check" }, .{
        .backend = "tracy-capture",
        .available = true,
        .basis = "ok",
    });
    const tracy_probe = try zigTracyProbe(&app, allocator, tracy_probe_args.value);
    try std.testing.expect(tracy_probe.value.object.get("backend_status").?.object.get("ok").?.bool);

    var preview_args = try parsedArgs(allocator,
        \\{"command":"zig build","samply_path":"samply","output":"profiles/samply.json"}
    );
    defer preview_args.deinit();
    try expectResolveOutput(&workspace, "profiles/samply.json", "/repo/profiles/samply.json");
    const preview = try zigSamplyRecord(&app, allocator, preview_args.value);
    try std.testing.expect(!preview.value.object.get("applied").?.bool);

    var unavailable_args = try parsedArgs(allocator,
        \\{"command":"zig build","samply_path":"missing-samply","output":"profiles/missing.json","apply":true}
    );
    defer unavailable_args.deinit();
    try expectResolveOutput(&workspace, "profiles/missing.json", "/repo/profiles/missing.json");
    try probe.expectCheck(.{ .backend = "samply", .argv = &.{ "missing-samply", "--help" }, .cwd = "/repo", .timeout_ms = 1000, .provenance = "arch110-workflow-backend-check" }, .{
        .backend = "samply",
        .available = false,
        .unavailable_reason = "not installed",
        .basis = "PATH probe",
    });
    const unavailable = try zigSamplyRecord(&app, allocator, unavailable_args.value);
    try std.testing.expect(!unavailable.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("backend_error", unavailable.value.object.get("kind").?.string);

    var success_args = try parsedArgs(allocator,
        \\{"command":"zig build","samply_path":"samply","output":"profiles/samply.json","apply":true}
    );
    defer success_args.deinit();
    const samply_argv = &.{ "samply", "record", "-o", "/repo/profiles/samply.json", "--", "zig", "build" };
    try expectResolveOutput(&workspace, "profiles/samply.json", "/repo/profiles/samply.json");
    try probe.expectCheck(.{ .backend = "samply", .argv = &.{ "samply", "--help" }, .cwd = "/repo", .timeout_ms = 1000, .provenance = "arch110-workflow-backend-check" }, .{
        .backend = "samply",
        .available = true,
        .basis = "ok",
    });
    try workspace.expectEnsureDir(.{ .path = "profiles", .provenance = "arch110-workflow-ensure-parent" }, .{});
    try commands.expectRun(commandRequest(samply_argv, 1000), .{ .exit_code = 0, .stdout = "", .stderr = "", .duration_ms = 5 });
    try workspace.expectRead(.{ .path = "profiles/samply.json", .max_bytes = max_evidence_bytes, .provenance = "arch110-workflow-read" }, "{\"profile\":true}");
    try expectResolveInput(&workspace, "profiles/samply.json", "/repo/profiles/samply.json");
    try expectArtifactRecord(allocator, &artifacts_fake, "profiles/samply.json", "zig_samply_record", "samply_profile", samply_argv, "samply", "", "", "captured Samply profile");
    const captured = try zigSamplyRecord(&app, allocator, success_args.value);
    try std.testing.expect(captured.value.object.get("applied").?.bool);

    var failed_args = try parsedArgs(allocator,
        \\{"tracy_capture_path":"tracy-capture","output":"profiles/failed.tracy","apply":true}
    );
    defer failed_args.deinit();
    const tracy_failed_argv = &.{ "tracy-capture", "-o", "/repo/profiles/failed.tracy", "-a", "127.0.0.1", "-p", "8086", "-s", "5" };
    try expectResolveOutput(&workspace, "profiles/failed.tracy", "/repo/profiles/failed.tracy");
    try probe.expectCheck(.{ .backend = "tracy-capture", .argv = &.{ "tracy-capture", "--help" }, .cwd = "/repo", .timeout_ms = 1000, .provenance = "arch110-workflow-backend-check" }, .{
        .backend = "tracy-capture",
        .available = true,
        .basis = "ok",
    });
    try workspace.expectEnsureDir(.{ .path = "profiles", .provenance = "arch110-workflow-ensure-parent" }, .{});
    try commands.expectRun(commandRequest(tracy_failed_argv, 1000), .{ .exit_code = 2, .stdout = "", .stderr = "refused\n", .duration_ms = 4 });
    const failed = try zigTracyCapture(&app, allocator, failed_args.value);
    try std.testing.expect(!failed.value.object.get("ok").?.bool);

    var tracy_args = try parsedArgs(allocator,
        \\{"tracy_capture_path":"tracy-capture","output":"profiles/capture.tracy","address":"127.0.0.2","port":8087,"seconds":1,"apply":true}
    );
    defer tracy_args.deinit();
    const tracy_argv = &.{ "tracy-capture", "-o", "/repo/profiles/capture.tracy", "-a", "127.0.0.2", "-p", "8087", "-s", "1" };
    try expectResolveOutput(&workspace, "profiles/capture.tracy", "/repo/profiles/capture.tracy");
    try probe.expectCheck(.{ .backend = "tracy-capture", .argv = &.{ "tracy-capture", "--help" }, .cwd = "/repo", .timeout_ms = 1000, .provenance = "arch110-workflow-backend-check" }, .{
        .backend = "tracy-capture",
        .available = true,
        .basis = "ok",
    });
    try workspace.expectEnsureDir(.{ .path = "profiles", .provenance = "arch110-workflow-ensure-parent" }, .{});
    try commands.expectRun(commandRequest(tracy_argv, 1000), .{ .exit_code = 0, .stdout = "", .stderr = "", .duration_ms = 6 });
    try workspace.expectRead(.{ .path = "profiles/capture.tracy", .max_bytes = max_evidence_bytes, .provenance = "arch110-workflow-read" }, "trace");
    try expectResolveInput(&workspace, "profiles/capture.tracy", "/repo/profiles/capture.tracy");
    try expectArtifactRecord(allocator, &artifacts_fake, "profiles/capture.tracy", "zig_tracy_capture", "tracy_capture", tracy_argv, "tracy-capture", "", "", "captured Tracy trace");
    const tracy = try zigTracyCapture(&app, allocator, tracy_args.value);
    try std.testing.expect(tracy.value.object.get("applied").?.bool);

    const windows_context = performanceTestContext(&commands, &workspace, &scanner, &probe, &artifacts_fake, .{ .os = "windows", .arch = "x86_64", .is_windows = true });
    var windows_app = App.init(windows_context, allocator);
    const unsupported = try zigTracyCapture(&windows_app, allocator, null);
    try std.testing.expect(!unsupported.value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("unsupported_platform", unsupported.value.object.get("error_kind").?.string);

    try commands.verify();
    try workspace.verify();
    try scanner.verify();
    try probe.verify();
    try artifacts_fake.verify();
}

test "performance artifact pack apply writes artifacts and hashes existing preimages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var artifacts_fake = fakes.FakeArtifactStore.init(std.testing.allocator);
    defer artifacts_fake.deinit();
    const context = performanceTestContext(&commands, &workspace, &scanner, null, &artifacts_fake, .{});
    var app = App.init(context, allocator);

    var pack_args = try parsedArgs(allocator,
        \\{"coverage":"coverage/run.json","benchmarks":"bench/run.json","output":"perf/evidence.json","apply":true}
    );
    defer pack_args.deinit();

    var obj = std.json.ObjectMap.empty;
    try putBase(allocator, &obj, &app, "zig_perf_evidence_pack", "Performance evidence bundle", "medium", &.{
        "Evidence pack stores supplied evidence and pointers; it does not run validation.",
    });
    var evidence = std.json.Array.init(allocator);
    try appendEvidencePointer(allocator, &evidence, "coverage", "coverage/run.json");
    try appendEvidencePointer(allocator, &evidence, "benchmarks", "bench/run.json");
    try appendEvidencePointer(allocator, &evidence, "samply", null);
    try appendEvidencePointer(allocator, &evidence, "tracy", null);
    try appendEvidencePointer(allocator, &evidence, "flamegraph", null);
    try appendEvidencePointer(allocator, &evidence, "validation", null);
    try obj.put(allocator, "evidence", .{ .array = evidence });
    try obj.put(allocator, "evidence_count", .{ .integer = 6 });
    try obj.put(allocator, "ready_for_review", .{ .bool = true });
    const expected_bytes = try serializeAlloc(allocator, .{ .object = obj });

    try expectResolveOutput(&workspace, "perf/evidence.json", "/repo/perf/evidence.json");
    try workspace.expectRead(.{ .path = "perf/evidence.json", .max_bytes = max_evidence_bytes, .provenance = "arch110-workflow-read" }, "old evidence");
    try workspace.expectWrite(.{
        .path = "perf/evidence.json",
        .bytes = expected_bytes,
        .create_parent_dirs = true,
        .replace_existing = true,
        .provenance = "arch110-workflow-write",
    }, .{ .bytes_written = expected_bytes.len, .replaced_existing = true });
    try expectResolveOutput(&workspace, "perf/evidence.json", "/repo/perf/evidence.json");
    try expectArtifactRecord(allocator, &artifacts_fake, "perf/evidence.json", "zig_perf_evidence_pack", "performance_evidence_pack", &.{}, "", "", "", "performance workflow artifact");

    const pack = try zigPerfEvidencePack(&app, allocator, pack_args.value);
    try std.testing.expect(pack.value.object.get("applied").?.bool);
    try std.testing.expect(pack.value.object.get("preimage_identity").?.object.get("exists").?.bool);

    try commands.verify();
    try workspace.verify();
    try scanner.verify();
    try artifacts_fake.verify();
}
