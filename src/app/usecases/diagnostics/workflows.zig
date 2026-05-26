const std = @import("std");

const app_context = @import("../../context.zig");
const support = @import("../usecase_support.zig");
const zig_analysis = @import("../../../domain/zig/analysis.zig");
const crash_evidence = @import("crash_evidence.zig");
const diagnostic_crash = @import("../../../domain/diagnostics/crash.zig");
const diagnostic_stack = @import("../../../domain/diagnostics/stacktrace.zig");

/// Aliases the app context wrapper used by this workflow module.
pub const App = support.UsecaseApp(app_context.DiagnosticsContext);
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
/// Aliases the shared command-error serializer for structured payloads.
const commandErrorValue = support.commandErrorValue;
/// Aliases the shared command-result serializer for structured payloads.
const commandResultValue = support.commandResultValue;
const lineNumberLocal = support.lineNumberLocal;
const missingArgumentResult = support.missingArgumentResult;
const recordWrittenArtifact = support.recordWrittenArtifact;
const runCommand = support.runCommand;
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
const max_binary_bytes = 64 * 1024 * 1024;

/// Carries evidence input data across use case and port boundaries.
const EvidenceInput = struct {
    bytes: []const u8,
    source_kind: []const u8,
    path: ?[]const u8 = null,
    owned: ?[]u8 = null,
    owned_allocator: ?std.mem.Allocator = null,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    fn deinit(self: EvidenceInput, allocator: std.mem.Allocator) void {
        if (self.owned) |owned| (self.owned_allocator orelse allocator).free(owned);
    }
};

/// Carries binary info data across use case and port boundaries.
const BinaryInfo = struct {
    path: []const u8,
    abs_path: []const u8,
    bytes_len: usize,
    sha256: []const u8,
    format: []const u8,
    stripped_hint: []const u8,
};

/// Executes the zig debug plan workflow and returns an allocator-owned structured result.
pub fn zigDebugPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = try baseValue(scratch, a, "zig_debug_plan", "Debugger session plan", "medium", &.{
        "Plans are advisory and do not prove root cause.",
        "Debugger availability is reported only when probe_backend=true.",
    });
    const lldb_path = argString(args, "lldb_path") orelse "lldb";
    if (argBool(args, "probe_backend", false)) {
        const probe = checkBackend(a, scratch, "lldb", &.{ lldb_path, "--version" }, @min(toolTimeout(a, args), 5000));
        try obj.put(scratch, "backend_status", try backendStatusValue(scratch, "lldb", probe.ok, probe.status, probe.resolution, lldb_path));
    } else {
        try obj.put(scratch, "backend_status", try backendStatusValue(scratch, "lldb", false, "not_probed", "Pass probe_backend=true to run lldb --version.", lldb_path));
    }
    try obj.put(scratch, "binary", stringOrNull(argString(args, "binary")));
    try obj.put(scratch, "core", stringOrNull(argString(args, "core")));
    try obj.put(scratch, "target", stringOrNull(argString(args, "target")));
    try obj.put(scratch, "repro_command", stringOrNull(argString(args, "command")));
    try obj.put(scratch, "recommended_tools", try stringArrayValue(scratch, &.{ "zig_lldb_backtrace", "zig_core_inspect", "zig_debug_frame_summary", "zig_panic_trace_analyze", "zig_sanitizer_fusion" }));
    try obj.put(scratch, "steps", try stringArrayValue(scratch, &.{
        "Build the failing target with debug info and without stripping.",
        "Capture the exact command, environment, target triple, crash log, and binary identity.",
        "Use zig_lldb_backtrace for a live binary or zig_core_inspect for a core dump when LLDB is installed.",
        "Fuse debugger frames with sanitizer or panic output before assigning root cause.",
    }));
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig lldb backtrace workflow and returns an allocator-owned structured result.
pub fn zigLldbBacktrace(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    if (a.context.platform.is_windows) return unsupportedBackendResult(a, allocator, "lldb", "backtrace", "LLDB backtrace capture is not supported by zigar on Windows.");
    const binary = argString(args, "binary") orelse return missingArgumentResult(allocator, "zig_lldb_backtrace", "binary", "workspace executable path");
    return lldbCapture(a, allocator, args, "zig_lldb_backtrace", binary, argString(args, "core"), "bt all", "LLDB backtrace preview");
}

/// Executes the zig core inspect workflow and returns an allocator-owned structured result.
pub fn zigCoreInspect(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    if (a.context.platform.is_windows) return unsupportedBackendResult(a, allocator, "lldb", "core_inspect", "Core dump inspection is not supported by zigar on Windows.");
    const core = argString(args, "core") orelse return missingArgumentResult(allocator, "zig_core_inspect", "core", "workspace core dump path");
    const binary = argString(args, "binary") orelse core;
    return lldbCapture(a, allocator, args, "zig_core_inspect", binary, core, "thread backtrace all", "LLDB core inspection preview");
}

/// Executes the zig debug frame summary workflow and returns an allocator-owned structured result.
pub fn zigDebugFrameSummary(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_debug_frame_summary", "text", "path", "content", true) catch |err| return evidenceInputError(a, allocator, "zig_debug_frame_summary", args, "text", err);
    defer input.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = try baseValue(scratch, a, "zig_debug_frame_summary", "Debugger frame text summary", "medium", &.{
        "Frame parsing is textual and should be cross-checked against the original debugger output.",
    });
    var summary = try crash_evidence.summarizeFrames(scratch, .{
        .bytes = input.bytes,
        .source_kind = input.source_kind,
        .limit = @intCast(@max(1, argInt(args, "limit", 40))),
    });
    defer summary.deinit(scratch);
    try obj.put(scratch, "source_kind", .{ .string = input.source_kind });
    try obj.put(scratch, "frames", try frameArrayValue(scratch, summary.frames.frames));
    try obj.put(scratch, "frame_count", .{ .integer = @intCast(summary.frames.count) });
    try obj.put(scratch, "top_frame", try topFrameValue(scratch, summary.frames));
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig sanitizer fusion workflow and returns an allocator-owned structured result.
pub fn zigSanitizerFusion(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_sanitizer_fusion", "text", "path", "content", true) catch |err| return evidenceInputError(a, allocator, "zig_sanitizer_fusion", args, "text", err);
    defer input.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = try baseValue(scratch, a, "zig_sanitizer_fusion", "Sanitizer and crash log fusion", "medium", &.{
        "Sanitizer output identifies a failing symptom; source-level root cause still needs code review and a repro.",
    });
    var fusion = try crash_evidence.fuseSanitizer(scratch, .{
        .bytes = input.bytes,
        .source_kind = input.source_kind,
        .limit = @intCast(@max(1, argInt(args, "limit", 40))),
    });
    defer fusion.deinit(scratch);
    try obj.put(scratch, "source_kind", .{ .string = input.source_kind });
    try obj.put(scratch, "sanitizer", .{ .string = fusion.sanitizer.name() });
    try obj.put(scratch, "failure_kind", .{ .string = fusion.failure_kind.name() });
    try obj.put(scratch, "crash_identity", .{ .string = fusion.crash_identity.value });
    try obj.put(scratch, "frames", try frameArrayValue(scratch, fusion.frames.frames));
    try obj.put(scratch, "frame_count", .{ .integer = @intCast(fusion.frames.count) });
    try obj.put(scratch, "repro_command", stringOrNull(argString(args, "command")));
    try obj.put(scratch, "verify_with", try stringArrayValue(scratch, &.{ "zig_crash_repro_plan", "zig_lldb_backtrace", "zig_valgrind_memcheck" }));
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig panic trace analyze workflow and returns an allocator-owned structured result.
pub fn zigPanicTraceAnalyze(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_panic_trace_analyze", "text", "path", "content", true) catch |err| return evidenceInputError(a, allocator, "zig_panic_trace_analyze", args, "text", err);
    defer input.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = try baseValue(scratch, a, "zig_panic_trace_analyze", "Zig panic trace analysis", "medium", &.{
        "Panic traces show the observed failure path and may omit optimized frames.",
    });
    var panic = try crash_evidence.analyzePanicTrace(scratch, .{
        .bytes = input.bytes,
        .source_kind = input.source_kind,
        .limit = @intCast(@max(1, argInt(args, "limit", 40))),
    });
    defer panic.deinit(scratch);
    try obj.put(scratch, "panic_message", .{ .string = panic.panic_message });
    try obj.put(scratch, "failure_kind", .{ .string = panic.failure_kind.name() });
    try obj.put(scratch, "crash_identity", .{ .string = panic.crash_identity.value });
    try obj.put(scratch, "frames", try frameArrayValue(scratch, panic.frames.frames));
    try obj.put(scratch, "frame_count", .{ .integer = @intCast(panic.frames.count) });
    try obj.put(scratch, "repro_command", stringOrNull(argString(args, "command")));
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig crash repro plan workflow and returns an allocator-owned structured result.
pub fn zigCrashReproPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_crash_repro_plan", "text", "path", "content", false) catch |err| return evidenceInputError(a, allocator, "zig_crash_repro_plan", args, "text", err);
    defer input.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = try baseValue(scratch, a, "zig_crash_repro_plan", "Crash reproduction plan", "medium", &.{
        "The plan is not proof of reproducibility until the command is rerun in a controlled environment.",
    });
    try obj.put(scratch, "repro_command", stringOrNull(argString(args, "command")));
    try obj.put(scratch, "target", stringOrNull(argString(args, "target")));
    var plan = try crash_evidence.planCrashRepro(scratch, input.bytes);
    defer plan.deinit(scratch);
    try obj.put(scratch, "failure_kind", .{ .string = plan.failure_kind.name() });
    try obj.put(scratch, "crash_identity", .{ .string = plan.crash_identity.value });
    try obj.put(scratch, "steps", try stringArrayValue(scratch, &.{
        "Record the exact command argv, environment variables, input file, target triple, and binary hash.",
        "Re-run once under the normal test command to confirm the failure is reproducible.",
        "Use sanitizer, panic, debugger, or memory tools to collect one stronger evidence source.",
        "Reduce the input only after the unreduced crash identity is preserved.",
    }));
    return structured(allocator, .{ .object = obj });
}

/// Invokes zig heaptrack run with caller-owned inputs; command and allocation failures propagate.
pub fn zigHeaptrackRun(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const command_text = argString(args, "command") orelse return missingArgumentResult(allocator, "zig_heaptrack_run", "command", "non-empty command string");
    const heaptrack_path = argString(args, "heaptrack_path") orelse "heaptrack";
    const output = argString(args, "output") orelse ".zigar-cache/memory/heaptrack.gz";
    const command_argv = splitToolArgs(allocator, command_text) catch |err| return splitToolArgsErrorResult(allocator, "zig_heaptrack_run", "command", command_text, err);
    defer freeArgv(allocator, command_argv);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const output_abs = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_heaptrack_run", output, err);
    defer a.workspace.allocator.free(output_abs);
    const argv = try concatArgv(scratch, &.{ heaptrack_path, "-o", output_abs, "--" }, command_argv);
    if (!argBool(args, "apply", false)) return previewResult(a, allocator, scratch, "zig_heaptrack_run", "heaptrack", heaptrack_path, argv, "heaptrack capture", argString(args, "target"), output);
    if (!a.context.platform.is_linux) return unsupportedBackendResult(a, allocator, "heaptrack", "run", "heaptrack capture is supported by zigar only on Linux.");
    return applyGatedBackendCommand(a, allocator, scratch, args, .{
        .tool_name = "zig_heaptrack_run",
        .backend_name = "heaptrack",
        .operation = "run",
        .configured_path = heaptrack_path,
        .probe_argv = &.{ heaptrack_path, "--help" },
        .argv = argv,
        .output = output,
        .artifact_kind = "heaptrack_capture",
        .basis = "heaptrack capture",
        .notes = "heaptrack runtime evidence",
    });
}

/// Executes the zig heaptrack summary workflow and returns an allocator-owned structured result.
pub fn zigHeaptrackSummary(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_heaptrack_summary", "text", "path", "content", true) catch |err| return evidenceInputError(a, allocator, "zig_heaptrack_summary", args, "text", err);
    defer input.deinit(allocator);
    return memorySummary(a, allocator, args, "zig_heaptrack_summary", input, "heaptrack");
}

/// Executes the zig valgrind memcheck workflow and returns an allocator-owned structured result.
pub fn zigValgrindMemcheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const command_text = argString(args, "command") orelse return missingArgumentResult(allocator, "zig_valgrind_memcheck", "command", "non-empty command string");
    const valgrind_path = argString(args, "valgrind_path") orelse "valgrind";
    const output = argString(args, "output") orelse ".zigar-cache/memory/valgrind-memcheck.json";
    const command_argv = splitToolArgs(allocator, command_text) catch |err| return splitToolArgsErrorResult(allocator, "zig_valgrind_memcheck", "command", command_text, err);
    defer freeArgv(allocator, command_argv);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const argv = try concatArgv(scratch, &.{ valgrind_path, "--tool=memcheck", "--leak-check=full", "--error-exitcode=99" }, command_argv);
    if (!argBool(args, "apply", false)) return previewResult(a, allocator, scratch, "zig_valgrind_memcheck", "valgrind", valgrind_path, argv, "Valgrind memcheck run", argString(args, "target"), output);
    if (!a.context.platform.is_linux) return unsupportedBackendResult(a, allocator, "valgrind", "memcheck", "Valgrind memcheck is supported by zigar only on Linux.");
    return applyGatedBackendCommand(a, allocator, scratch, args, .{
        .tool_name = "zig_valgrind_memcheck",
        .backend_name = "valgrind",
        .operation = "memcheck",
        .configured_path = valgrind_path,
        .probe_argv = &.{ valgrind_path, "--version" },
        .argv = argv,
        .output = output,
        .artifact_kind = "valgrind_memcheck",
        .basis = "Valgrind memcheck run",
        .notes = "Valgrind memcheck runtime evidence",
    });
}

/// Executes the zig callgrind report workflow and returns an allocator-owned structured result.
pub fn zigCallgrindReport(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    if (argString(args, "content") != null or argString(args, "path") != null or argString(args, "text") != null) {
        var input = readEvidenceInput(a, allocator, args, "zig_callgrind_report", "text", "path", "content", true) catch |err| return evidenceInputError(a, allocator, "zig_callgrind_report", args, "text", err);
        defer input.deinit(allocator);
        return callgrindSummary(a, allocator, args, input);
    }
    const command_text = argString(args, "command") orelse return missingArgumentResult(allocator, "zig_callgrind_report", "command", "command string or callgrind content/path");
    const valgrind_path = argString(args, "valgrind_path") orelse "valgrind";
    const output = argString(args, "output") orelse ".zigar-cache/memory/callgrind.out";
    const command_argv = splitToolArgs(allocator, command_text) catch |err| return splitToolArgsErrorResult(allocator, "zig_callgrind_report", "command", command_text, err);
    defer freeArgv(allocator, command_argv);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const output_abs = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_callgrind_report", output, err);
    defer a.workspace.allocator.free(output_abs);
    const out_arg = try std.fmt.allocPrint(scratch, "--callgrind-out-file={s}", .{output_abs});
    const argv = try concatArgv(scratch, &.{ valgrind_path, "--tool=callgrind", out_arg }, command_argv);
    if (!argBool(args, "apply", false)) return previewResult(a, allocator, scratch, "zig_callgrind_report", "valgrind", valgrind_path, argv, "Valgrind callgrind run", argString(args, "target"), output);
    if (!a.context.platform.is_linux) return unsupportedBackendResult(a, allocator, "valgrind", "callgrind", "Valgrind callgrind is supported by zigar only on Linux.");
    return applyGatedBackendCommand(a, allocator, scratch, args, .{
        .tool_name = "zig_callgrind_report",
        .backend_name = "valgrind",
        .operation = "callgrind",
        .configured_path = valgrind_path,
        .probe_argv = &.{ valgrind_path, "--version" },
        .argv = argv,
        .output = output,
        .artifact_kind = "callgrind_report",
        .basis = "Valgrind callgrind run",
        .notes = "Valgrind callgrind evidence",
    });
}

/// Executes the zig fuzz plan workflow and returns an allocator-owned structured result.
pub fn zigFuzzPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = try baseValue(scratch, a, "zig_fuzz_plan", "Fuzzing workflow plan", "medium", &.{
        "Fuzzing evidence is time-boxed and input-dependent; absence of crashes is not proof of correctness.",
    });
    try obj.put(scratch, "target", stringOrNull(argString(args, "target")));
    try obj.put(scratch, "command", stringOrNull(argString(args, "command")));
    try obj.put(scratch, "recommended_tools", try stringArrayValue(scratch, &.{ "zig_afl_run", "zig_libfuzzer_run", "zig_fuzz_corpus_summary", "zig_fuzz_crash_minimize", "zig_sanitizer_fusion" }));
    try obj.put(scratch, "steps", try stringArrayValue(scratch, &.{
        "Define a deterministic harness with bounded input size and reproducible seed corpus.",
        "Run a short smoke campaign before long-running CI or local fuzzing jobs.",
        "Preserve crashing inputs and command argv before minimizing.",
        "Fuse minimized crashes with sanitizer, panic, debugger, or memory-tool evidence.",
    }));
    return structured(allocator, .{ .object = obj });
}

/// Invokes zig afl run with caller-owned inputs; command and allocation failures propagate.
pub fn zigAflRun(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const command_text = argString(args, "command") orelse return missingArgumentResult(allocator, "zig_afl_run", "command", "fuzz target command string");
    const afl_path = argString(args, "afl_path") orelse "afl-fuzz";
    const corpus = argString(args, "corpus") orelse "corpus";
    const output = argString(args, "output") orelse ".zigar-cache/fuzz/afl";
    const command_argv = splitToolArgs(allocator, command_text) catch |err| return splitToolArgsErrorResult(allocator, "zig_afl_run", "command", command_text, err);
    defer freeArgv(allocator, command_argv);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const corpus_abs = a.workspace.resolve(corpus) catch |err| return workspacePathErrorResult(a, allocator, "zig_afl_run", corpus, err);
    defer a.workspace.allocator.free(corpus_abs);
    const output_abs = a.workspace.resolveOutput(output) catch |err| return workspacePathErrorResult(a, allocator, "zig_afl_run", output, err);
    defer a.workspace.allocator.free(output_abs);
    const argv = try concatArgv(scratch, &.{ afl_path, "-i", corpus_abs, "-o", output_abs, "--" }, command_argv);
    if (!argBool(args, "apply", false)) return previewResult(a, allocator, scratch, "zig_afl_run", "afl-fuzz", afl_path, argv, "AFL++ fuzz run", argString(args, "target"), output);
    if (a.context.platform.is_windows) return unsupportedBackendResult(a, allocator, "afl-fuzz", "run", "AFL++ execution is not supported by zigar on Windows.");
    return applyGatedBackendCommand(a, allocator, scratch, args, .{
        .tool_name = "zig_afl_run",
        .backend_name = "afl-fuzz",
        .operation = "run",
        .configured_path = afl_path,
        .probe_argv = &.{ afl_path, "-h" },
        .argv = argv,
        .output = output,
        .artifact_kind = "afl_fuzz_run",
        .basis = "AFL++ fuzz run",
        .notes = "AFL++ fuzz evidence",
    });
}

/// Invokes zig libfuzzer run with caller-owned inputs; command and allocation failures propagate.
pub fn zigLibfuzzerRun(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const command_text = argString(args, "command") orelse return missingArgumentResult(allocator, "zig_libfuzzer_run", "command", "libFuzzer command string");
    const output = argString(args, "output") orelse ".zigar-cache/fuzz/libfuzzer-run.json";
    const argv = splitToolArgs(allocator, command_text) catch |err| return splitToolArgsErrorResult(allocator, "zig_libfuzzer_run", "command", command_text, err);
    defer freeArgv(allocator, argv);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    return applyGatedUserCommand(a, allocator, scratch, args, "zig_libfuzzer_run", argv, output, "libfuzzer_run", "libFuzzer run evidence");
}

/// Executes the zig fuzz crash minimize workflow and returns an allocator-owned structured result.
pub fn zigFuzzCrashMinimize(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var input = readEvidenceInput(a, allocator, args, "zig_fuzz_crash_minimize", "text", "path", "content", false) catch |err| return evidenceInputError(a, allocator, "zig_fuzz_crash_minimize", args, "text", err);
    defer input.deinit(allocator);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const command_text = argString(args, "command") orelse "<fuzz-target>";
    var obj = try baseValue(scratch, a, "zig_fuzz_crash_minimize", "Fuzz crash minimization plan", "medium", &.{
        "This tool returns deterministic minimization plans; it does not run reducers.",
    });
    try obj.put(scratch, "crash_identity", try identityFromText(scratch, input.bytes, "fuzz_crash"));
    try obj.put(scratch, "afl_tmin_argv", try stringArrayValue(scratch, &.{ "afl-tmin", "-i", "<crash-input>", "-o", "<minimized-output>", "--", command_text }));
    try obj.put(scratch, "libfuzzer_argv", try stringArrayValue(scratch, &.{ command_text, "-minimize_crash=1", "<crash-input>" }));
    try obj.put(scratch, "stop_condition", .{ .string = "The minimized input must reproduce the same crash identity under the original command." });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig fuzz corpus summary workflow and returns an allocator-owned structured result.
pub fn zigFuzzCorpusSummary(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const path = argString(args, "path") orelse return missingArgumentResult(allocator, "zig_fuzz_corpus_summary", "path", "workspace corpus directory");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const value = corpusSummaryValue(scratch, a, path, @intCast(@max(1, argInt(args, "limit", 50)))) catch |err| return workspacePathErrorResult(a, allocator, "zig_fuzz_corpus_summary", path, err);
    return structured(allocator, value);
}

/// Executes the zig binary size workflow and returns an allocator-owned structured result.
pub fn zigBinarySize(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const path = argString(args, "path") orelse return missingArgumentResult(allocator, "zig_binary_size", "path", "workspace binary path");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const info = binaryInfo(a, scratch, path) catch |err| return workspacePathErrorResult(a, allocator, "zig_binary_size", path, err);
    var obj = try baseValue(scratch, a, "zig_binary_size", "Binary artifact size", "high", &.{
        "Format sniffing is based on file magic and does not replace platform-specific binary inspection.",
    });
    try putBinaryInfo(scratch, &obj, info);
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig binary size diff workflow and returns an allocator-owned structured result.
pub fn zigBinarySizeDiff(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const after_path = argString(args, "path") orelse return missingArgumentResult(allocator, "zig_binary_size_diff", "path", "workspace current binary path");
    const before_path = argString(args, "baseline") orelse return missingArgumentResult(allocator, "zig_binary_size_diff", "baseline", "workspace baseline binary path");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const before = binaryInfo(a, scratch, before_path) catch |err| return workspacePathErrorResult(a, allocator, "zig_binary_size_diff", before_path, err);
    const after = binaryInfo(a, scratch, after_path) catch |err| return workspacePathErrorResult(a, allocator, "zig_binary_size_diff", after_path, err);
    var obj = try baseValue(scratch, a, "zig_binary_size_diff", "Binary size comparison", "high", &.{
        "Size deltas do not explain why code size changed; inspect sections and symbols for attribution.",
    });
    try obj.put(scratch, "baseline_binary", try binaryInfoValue(scratch, before));
    try obj.put(scratch, "current_binary", try binaryInfoValue(scratch, after));
    try obj.put(scratch, "size_delta_bytes", .{ .integer = @as(i64, @intCast(after.bytes_len)) - @as(i64, @intCast(before.bytes_len)) });
    try obj.put(scratch, "size_delta_pct", .{ .float = pctDelta(before.bytes_len, after.bytes_len) });
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig objdump summary workflow and returns an allocator-owned structured result.
pub fn zigObjdumpSummary(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return binaryBackendTool(a, allocator, args, .{
        .tool_name = "zig_objdump_summary",
        .backend_name = "llvm-objdump",
        .path_arg = "objdump_path",
        .default_path = "llvm-objdump",
        .operation = "summary",
        .extra_args = &.{ "-h", "-t" },
        .basis = "llvm-objdump section and symbol summary",
    });
}

/// Executes the zig dwarfdump check workflow and returns an allocator-owned structured result.
pub fn zigDwarfdumpCheck(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return binaryBackendTool(a, allocator, args, .{
        .tool_name = "zig_dwarfdump_check",
        .backend_name = "llvm-dwarfdump",
        .path_arg = "dwarfdump_path",
        .default_path = "llvm-dwarfdump",
        .operation = "verify",
        .extra_args = &.{"--verify"},
        .basis = "llvm-dwarfdump debug info verification",
    });
}

/// Executes the zig symbolize workflow and returns an allocator-owned structured result.
pub fn zigSymbolize(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const addresses = argString(args, "addresses") orelse return missingArgumentResult(allocator, "zig_symbolize", "addresses", "one or more addresses");
    const path = argString(args, "path") orelse return missingArgumentResult(allocator, "zig_symbolize", "path", "workspace binary path");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const binary_abs = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zig_symbolize", path, err);
    defer a.workspace.allocator.free(binary_abs);
    var tokens = std.ArrayList([]const u8).empty;
    var it = std.mem.tokenizeAny(u8, addresses, ", \t\r\n");
    while (it.next()) |addr| try tokens.append(scratch, addr);
    const symbolizer = argString(args, "symbolizer_path") orelse "llvm-symbolizer";
    const argv = try concatArgv(scratch, &.{ symbolizer, "--obj", binary_abs }, tokens.items);
    return binaryApplyGatedCommand(a, allocator, scratch, args, "zig_symbolize", "llvm-symbolizer", "symbolize", symbolizer, argv, path, "Address symbolization preview");
}

/// Executes the zig qemu test workflow and returns an allocator-owned structured result.
pub fn zigQemuTest(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    const target = argString(args, "target") orelse "native";
    const qemu_path = argString(args, "qemu_path") orelse qemuDefaultForTarget(target);
    const command_text = argString(args, "command") orelse argString(args, "binary") orelse return missingArgumentResult(allocator, "zig_qemu_test", "command", "QEMU guest command or workspace binary path");
    const command_argv = splitToolArgs(allocator, command_text) catch |err| return splitToolArgsErrorResult(allocator, "zig_qemu_test", "command", command_text, err);
    defer freeArgv(allocator, command_argv);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const argv = try concatArgv(scratch, &.{qemu_path}, command_argv);
    if (!argBool(args, "apply", false)) return previewResult(a, allocator, scratch, "zig_qemu_test", "qemu", qemu_path, argv, "QEMU cross-target smoke run", target, ".zigar-cache/cross-target/qemu-test.json");
    if (a.context.platform.is_windows) return unsupportedBackendResult(a, allocator, "qemu", "test", "QEMU execution is not supported by zigar on Windows.");
    return applyGatedBackendCommand(a, allocator, scratch, args, .{
        .tool_name = "zig_qemu_test",
        .backend_name = "qemu",
        .operation = "test",
        .configured_path = qemu_path,
        .probe_argv = &.{ qemu_path, "--version" },
        .argv = argv,
        .output = ".zigar-cache/cross-target/qemu-test.json",
        .artifact_kind = "qemu_test",
        .basis = "QEMU cross-target smoke run",
        .notes = "QEMU target runtime evidence",
        .target = target,
    });
}

/// Executes the zig cross smoke workflow and returns an allocator-owned structured result.
pub fn zigCrossSmoke(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return crossPlan(a, allocator, args, "zig_cross_smoke", "Cross-target smoke matrix");
}

/// Executes the zig target runtime plan workflow and returns an allocator-owned structured result.
pub fn zigTargetRuntimePlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    return crossPlan(a, allocator, args, "zig_target_runtime_plan", "Target runtime plan");
}

/// Executes the zig embedded detect workflow and returns an allocator-owned structured result.
pub fn zigEmbeddedDetect(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const value = embeddedDetectValue(arena.allocator(), a, @intCast(@max(1, argInt(args, "limit", 80)))) catch |err| return toolErrorFromError(allocator, .{
        .tool = "zig_embedded_detect",
        .operation = "scan_workspace",
        .phase = "embedded_detect",
        .code = "scan_failed",
        .category = "filesystem",
        .resolution = "Confirm the workspace is readable and retry with a smaller limit.",
    }, err);
    return structured(allocator, value);
}

/// Executes the zig microzig plan workflow and returns an allocator-owned structured result.
pub fn zigMicrozigPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = try baseValue(scratch, a, "zig_microzig_plan", "MicroZig workflow plan", "medium", &.{
        "MicroZig project detection is heuristic and should be verified against build.zig and board packages.",
    });
    try obj.put(scratch, "board", stringOrNull(argString(args, "board")));
    try obj.put(scratch, "target", stringOrNull(argString(args, "target")));
    try obj.put(scratch, "steps", try stringArrayValue(scratch, &.{
        "Identify the board package, CPU, memory map, linker script, and simulator or hardware target.",
        "Run a compile-only build for the selected target before flashing.",
        "Use zig_flash_plan to review flash commands and probe the backend without mutating hardware.",
        "Record firmware artifact identity and board profile with release or lab evidence.",
    }));
    try obj.put(scratch, "recommended_tools", try stringArrayValue(scratch, &.{ "zig_embedded_detect", "zig_board_profile", "zig_flash_plan", "zig_target_runtime_plan" }));
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig board profile workflow and returns an allocator-owned structured result.
pub fn zigBoardProfile(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const board = argString(args, "board") orelse "unknown";
    var obj = try baseValue(scratch, a, "zig_board_profile", "Embedded board profile", "medium", &.{
        "Board profiles are advisory unless backed by project configuration or hardware lab notes.",
    });
    try obj.put(scratch, "board", .{ .string = board });
    try obj.put(scratch, "target", .{ .string = argString(args, "target") orelse boardTarget(board) });
    try obj.put(scratch, "runtime", .{ .string = if (isCortexBoard(board)) "bare_metal_arm_cortex_m" else "project_defined" });
    try obj.put(scratch, "debug_interfaces", try stringArrayValue(scratch, if (isCortexBoard(board)) &.{ "swd", "jlink", "cmsis-dap", "probe-rs" } else &.{"project_defined"}));
    try obj.put(scratch, "flash_backends", try stringArrayValue(scratch, &.{ "probe-rs", "openocd", "pyocd", "vendor tool" }));
    try obj.put(scratch, "required_artifacts", try stringArrayValue(scratch, &.{ "firmware image identity", "board name", "target triple", "flash command", "probe backend/version" }));
    return structured(allocator, .{ .object = obj });
}

/// Executes the zig flash plan workflow and returns an allocator-owned structured result.
pub fn zigFlashPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const flash_tool = argString(args, "flash_tool") orelse "probe-rs";
    var obj = try baseValue(scratch, a, "zig_flash_plan", "Firmware flash plan", "medium", &.{
        "zigar never flashes hardware; returned commands are plans and optional probes only.",
    });
    if (argBool(args, "probe_backend", false)) {
        const probe = checkBackend(a, scratch, flash_tool, &.{ flash_tool, "--help" }, @min(toolTimeout(a, args), 5000));
        try obj.put(scratch, "backend_status", try backendStatusValue(scratch, flash_tool, probe.ok, probe.status, probe.resolution, flash_tool));
    } else {
        try obj.put(scratch, "backend_status", try backendStatusValue(scratch, flash_tool, false, "not_probed", "Pass probe_backend=true to run the flash tool with --help; zigar will not flash hardware.", flash_tool));
    }
    try obj.put(scratch, "board", stringOrNull(argString(args, "board")));
    try obj.put(scratch, "target", stringOrNull(argString(args, "target")));
    try obj.put(scratch, "image", stringOrNull(argString(args, "image")));
    try obj.put(scratch, "repro_command", .{ .string = try flashCommand(scratch, flash_tool, argString(args, "board"), argString(args, "image")) });
    try obj.put(scratch, "mutates_hardware", .{ .bool = false });
    try obj.put(scratch, "stop_condition", .{ .string = "Only run the flash command manually after confirming board, probe, power, image hash, and target voltage outside zigar." });
    return structured(allocator, .{ .object = obj });
}

/// Carries backend command spec data across use case and port boundaries.
const BackendCommandSpec = struct {
    tool_name: []const u8,
    backend_name: []const u8,
    operation: []const u8,
    configured_path: []const u8,
    probe_argv: []const []const u8,
    argv: []const []const u8,
    output: []const u8,
    artifact_kind: []const u8,
    basis: []const u8,
    notes: []const u8,
    target: []const u8 = "",
};

/// Implements lldb capture workflow logic using caller-owned inputs.
fn lldbCapture(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, binary: []const u8, core: ?[]const u8, command_expr: []const u8, basis: []const u8) !Result {
    const lldb_path = argString(args, "lldb_path") orelse "lldb";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const binary_abs = a.workspace.resolve(binary) catch |err| return workspacePathErrorResult(a, allocator, tool_name, binary, err);
    defer a.workspace.allocator.free(binary_abs);
    var argv_list = std.ArrayList([]const u8).empty;
    try argv_list.appendSlice(scratch, &.{ lldb_path, "--batch", "-o", command_expr });
    if (core) |core_path| {
        const core_abs = a.workspace.resolve(core_path) catch |err| return workspacePathErrorResult(a, allocator, tool_name, core_path, err);
        defer a.workspace.allocator.free(core_abs);
        try argv_list.appendSlice(scratch, &.{ "-c", try scratch.dupe(u8, core_abs) });
    }
    try argv_list.append(scratch, try scratch.dupe(u8, binary_abs));
    const argv = argv_list.items;
    if (!argBool(args, "apply", false)) return previewResult(a, allocator, scratch, tool_name, "lldb", lldb_path, argv, basis, argString(args, "target"), null);
    const probe = checkBackend(a, scratch, "lldb", &.{ lldb_path, "--version" }, @min(toolTimeout(a, args), 5000));
    if (!probe.ok) return backendUnavailableResult(allocator, "lldb", "debug_capture", lldb_path, probe.status, "Install LLDB separately or pass lldb_path to an existing executable; zigar never installs debugger tools.");
    const result = runCommand(allocator, a, argv, toolTimeout(a, args)) catch |err| return backendErrorResult(allocator, "lldb", "debug_capture", err, "Run the shown LLDB argv directly to inspect debugger-specific failures.");
    defer result.deinit(allocator);
    var obj = try baseValue(scratch, a, tool_name, "LLDB debugger capture", "medium", &.{
        "Debugger output is runtime evidence and must be fused with source, build mode, and repro data before root-cause claims.",
    });
    try obj.put(scratch, "backend_status", try backendStatusValue(scratch, "lldb", true, "ok", "LLDB command completed.", lldb_path));
    try obj.put(scratch, "command_argv", try argvValue(scratch, argv));
    try obj.put(scratch, "command_result", try commandResultValue(scratch, "lldb debug capture", argv, a.workspace.root, toolTimeout(a, args), result));
    var frames = try diagnostic_stack.parseFrames(scratch, result.stdout, @intCast(@max(1, argInt(args, "limit", 40))));
    defer frames.deinit(scratch);
    try obj.put(scratch, "frames", try frameArrayValue(scratch, frames.frames));
    try obj.put(scratch, "frame_count", .{ .integer = @intCast(frames.count) });
    try obj.put(scratch, "applied", .{ .bool = true });
    try obj.put(scratch, "requires_apply", .{ .bool = false });
    return structured(allocator, .{ .object = obj });
}

/// Implements apply gated backend command workflow logic using caller-owned inputs.
fn applyGatedBackendCommand(a: *App, result_allocator: std.mem.Allocator, scratch: std.mem.Allocator, args: ?std.json.Value, spec: BackendCommandSpec) !Result {
    if (!argBool(args, "apply", false)) return previewResult(a, result_allocator, scratch, spec.tool_name, spec.backend_name, spec.configured_path, spec.argv, spec.basis, if (spec.target.len > 0) spec.target else argString(args, "target"), spec.output);
    const probe = checkBackend(a, scratch, spec.backend_name, spec.probe_argv, @min(toolTimeout(a, args), 5000));
    if (!probe.ok) return backendUnavailableResult(result_allocator, spec.backend_name, spec.operation, spec.configured_path, probe.status, "Install or configure the optional backend outside zigar, then retry with the path argument; zigar never installs external tools.");
    const run = runCommand(result_allocator, a, spec.argv, toolTimeout(a, args)) catch |err| return backendErrorResult(result_allocator, spec.backend_name, spec.operation, err, "Run the shown backend argv directly to inspect backend-specific failures.");
    defer run.deinit(result_allocator);
    var obj = try baseValue(scratch, a, spec.tool_name, spec.basis, "medium", &.{
        "Runtime diagnostic evidence is backend-bound and does not prove correctness.",
    });
    try obj.put(scratch, "backend_status", try backendStatusValue(scratch, spec.backend_name, true, "ok", "Backend command completed.", spec.configured_path));
    try obj.put(scratch, "command_argv", try argvValue(scratch, spec.argv));
    try obj.put(scratch, "command_result", try commandResultValue(scratch, spec.basis, spec.argv, a.workspace.root, toolTimeout(a, args), run));
    try obj.put(scratch, "findings", try memoryFindingsValue(scratch, run.stderr));
    const preimage = preimageIdentityForPath(a, scratch, spec.output) catch .null;
    writeEvidenceArtifact(a, scratch, spec.output, .{ .object = obj }, spec.tool_name, spec.artifact_kind, spec.argv, spec.backend_name, spec.target, spec.notes) catch |err| return workspacePathErrorResult(a, result_allocator, spec.tool_name, spec.output, err);
    const bytes = try serializeAlloc(scratch, .{ .object = obj });
    try obj.put(scratch, "output", .{ .string = spec.output });
    try obj.put(scratch, "artifact_identity", artifactIdentityValue(scratch, a, spec.output, bytes) catch .null);
    try obj.put(scratch, "preimage_identity", preimage);
    try obj.put(scratch, "applied", .{ .bool = true });
    try obj.put(scratch, "requires_apply", .{ .bool = false });
    return structured(result_allocator, .{ .object = obj });
}

/// Implements apply gated user command workflow logic using caller-owned inputs.
fn applyGatedUserCommand(a: *App, result_allocator: std.mem.Allocator, scratch: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, argv: []const []const u8, output: []const u8, artifact_kind: []const u8, notes: []const u8) !Result {
    if (!argBool(args, "apply", false)) return previewResult(a, result_allocator, scratch, tool_name, "project_command", "", argv, "Project command preview", argString(args, "target"), output);
    const run = runCommand(result_allocator, a, argv, toolTimeout(a, args)) catch |err| {
        const value = commandErrorValue(scratch, "project diagnostic command", argv, a.workspace.root, toolTimeout(a, args), err) catch return error.OutOfMemory;
        return structured(result_allocator, value);
    };
    defer run.deinit(result_allocator);
    var obj = try baseValue(scratch, a, tool_name, "Executed project diagnostic command", "medium", &.{
        "Project command output is runtime evidence and may be nondeterministic.",
    });
    try obj.put(scratch, "command_argv", try argvValue(scratch, argv));
    try obj.put(scratch, "command_result", try commandResultValue(scratch, "project diagnostic command", argv, a.workspace.root, toolTimeout(a, args), run));
    const preimage = preimageIdentityForPath(a, scratch, output) catch .null;
    writeEvidenceArtifact(a, scratch, output, .{ .object = obj }, tool_name, artifact_kind, argv, "project_command", argString(args, "target") orelse "", notes) catch |err| return workspacePathErrorResult(a, result_allocator, tool_name, output, err);
    const bytes = try serializeAlloc(scratch, .{ .object = obj });
    try obj.put(scratch, "output", .{ .string = output });
    try obj.put(scratch, "artifact_identity", artifactIdentityValue(scratch, a, output, bytes) catch .null);
    try obj.put(scratch, "preimage_identity", preimage);
    try obj.put(scratch, "applied", .{ .bool = true });
    try obj.put(scratch, "requires_apply", .{ .bool = false });
    return structured(result_allocator, .{ .object = obj });
}

/// Carries binary backend spec data across use case and port boundaries.
const BinaryBackendSpec = struct {
    tool_name: []const u8,
    backend_name: []const u8,
    path_arg: []const u8,
    default_path: []const u8,
    operation: []const u8,
    extra_args: []const []const u8,
    basis: []const u8,
};

/// Implements binary backend tool workflow logic using caller-owned inputs.
fn binaryBackendTool(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, spec: BinaryBackendSpec) !Result {
    const path = argString(args, "path") orelse return missingArgumentResult(allocator, spec.tool_name, "path", "workspace binary path");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const binary_abs = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, spec.tool_name, path, err);
    defer a.workspace.allocator.free(binary_abs);
    const backend_path = argString(args, spec.path_arg) orelse spec.default_path;
    var prefix = std.ArrayList([]const u8).empty;
    try prefix.append(scratch, backend_path);
    try prefix.appendSlice(scratch, spec.extra_args);
    try prefix.append(scratch, try scratch.dupe(u8, binary_abs));
    const argv = prefix.items;
    return binaryApplyGatedCommand(a, allocator, scratch, args, spec.tool_name, spec.backend_name, spec.operation, backend_path, argv, path, spec.basis);
}

/// Implements binary apply gated command workflow logic using caller-owned inputs.
fn binaryApplyGatedCommand(a: *App, result_allocator: std.mem.Allocator, scratch: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, backend_name: []const u8, operation: []const u8, configured_path: []const u8, argv: []const []const u8, path: []const u8, basis: []const u8) !Result {
    if (!argBool(args, "apply", false)) return previewResult(a, result_allocator, scratch, tool_name, backend_name, configured_path, argv, basis, argString(args, "target"), null);
    const probe = checkBackend(a, scratch, backend_name, &.{ configured_path, "--version" }, @min(toolTimeout(a, args), 5000));
    if (!probe.ok) return backendUnavailableResult(result_allocator, backend_name, operation, configured_path, probe.status, "Install the LLVM binary tools separately or pass the per-call backend path; zigar never installs them.");
    const run = runCommand(result_allocator, a, argv, toolTimeout(a, args)) catch |err| return backendErrorResult(result_allocator, backend_name, operation, err, "Run the shown backend argv directly to inspect binary-tool-specific failures.");
    defer run.deinit(result_allocator);
    const info = binaryInfo(a, scratch, path) catch |err| return workspacePathErrorResult(a, result_allocator, tool_name, path, err);
    var obj = try baseValue(scratch, a, tool_name, basis, "medium", &.{
        "Binary tool summaries reflect backend text output and may need platform-specific review.",
    });
    try obj.put(scratch, "backend_status", try backendStatusValue(scratch, backend_name, true, "ok", "Backend command completed.", configured_path));
    try obj.put(scratch, "command_argv", try argvValue(scratch, argv));
    try obj.put(scratch, "command_result", try commandResultValue(scratch, basis, argv, a.workspace.root, toolTimeout(a, args), run));
    try putBinaryInfo(scratch, &obj, info);
    try obj.put(scratch, "sections", try sectionSummaryValue(scratch, run.stdout));
    try obj.put(scratch, "symbols", try symbolSummaryValue(scratch, run.stdout));
    try obj.put(scratch, "debug_info_status", .{ .string = if (std.mem.indexOf(u8, run.stdout, ".debug") != null or std.mem.indexOf(u8, run.stderr, ".debug") != null) "debug_info_seen" else "not_detected" });
    try obj.put(scratch, "applied", .{ .bool = true });
    try obj.put(scratch, "requires_apply", .{ .bool = false });
    return structured(result_allocator, .{ .object = obj });
}

/// Implements preview result workflow logic using caller-owned inputs.
fn previewResult(a: *App, result_allocator: std.mem.Allocator, scratch: std.mem.Allocator, tool_name: []const u8, backend: []const u8, configured_path: []const u8, argv: []const []const u8, basis: []const u8, target: ?[]const u8, output: ?[]const u8) !Result {
    var obj = try baseValue(scratch, a, tool_name, basis, "medium", &.{
        "The backend or project command is not executed until apply=true.",
    });
    try obj.put(scratch, "backend_status", try backendStatusValue(scratch, backend, false, "not_probed", "Preview only; no backend command was executed.", configured_path));
    try obj.put(scratch, "command_argv", try argvValue(scratch, argv));
    try obj.put(scratch, "target", stringOrNull(target));
    try obj.put(scratch, "applied", .{ .bool = false });
    try obj.put(scratch, "requires_apply", .{ .bool = true });
    try obj.put(scratch, "skipped_validation", try stringArrayValue(scratch, &.{"backend execution skipped by preview"}));
    if (output) |path| {
        try obj.put(scratch, "output", .{ .string = path });
        try obj.put(scratch, "preimage_identity", preimageIdentityForPath(a, scratch, path) catch .null);
    }
    return structured(result_allocator, .{ .object = obj });
}

/// Implements memory summary workflow logic using caller-owned inputs.
fn memorySummary(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, input: EvidenceInput, backend: []const u8) !Result {
    _ = args;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = try baseValue(scratch, a, tool_name, "Memory analysis evidence summary", "medium", &.{
        "Memory evidence is backend-specific and should be validated with a fresh run on the target platform.",
    });
    try obj.put(scratch, "source_kind", .{ .string = input.source_kind });
    try obj.put(scratch, "memory_backend", .{ .string = backend });
    try obj.put(scratch, "findings", try memoryFindingsValue(scratch, input.bytes));
    try obj.put(scratch, "memory_finding_identity", try identityFromText(scratch, input.bytes, backend));
    return structured(allocator, .{ .object = obj });
}

/// Implements callgrind summary workflow logic using caller-owned inputs.
fn callgrindSummary(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, input: EvidenceInput) !Result {
    _ = args;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = try baseValue(scratch, a, "zig_callgrind_report", "Callgrind report summary", "medium", &.{
        "Callgrind costs are workload-specific and need symbolized source review for attribution.",
    });
    try obj.put(scratch, "source_kind", .{ .string = input.source_kind });
    try obj.put(scratch, "events", try callgrindEventsValue(scratch, input.bytes));
    try obj.put(scratch, "hotspots", try callgrindHotspotsValue(scratch, input.bytes, 20));
    return structured(allocator, .{ .object = obj });
}

/// Implements cross plan workflow logic using caller-owned inputs.
fn crossPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, basis: []const u8) !Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var obj = try baseValue(scratch, a, tool_name, basis, "medium", &.{
        "Emulated target results are runtime smoke evidence, not a substitute for hardware or target CI when those are required.",
    });
    const targets_text = argString(args, "targets") orelse argString(args, "target") orelse "native";
    var targets = std.json.Array.init(scratch);
    var it = std.mem.tokenizeAny(u8, targets_text, ", \t\r\n");
    while (it.next()) |target| try targets.append(try targetPlanValue(scratch, target, argString(args, "command")));
    try obj.put(scratch, "targets", .{ .array = targets });
    try obj.put(scratch, "command", stringOrNull(argString(args, "command")));
    try obj.put(scratch, "recommended_tools", try stringArrayValue(scratch, &.{ "zig_target_matrix_plan", "zig_qemu_test", "zig_cross_smoke" }));
    return structured(allocator, .{ .object = obj });
}

/// Reads evidence input data from the provided context without taking ownership of inputs.
fn readEvidenceInput(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, primary: []const u8, path_field: ?[]const u8, content_field: ?[]const u8, required: bool) !EvidenceInput {
    _ = allocator;
    _ = tool_name;
    if (content_field) |field| if (argString(args, field)) |content| return .{ .bytes = content, .source_kind = field };
    if (argString(args, primary)) |value| {
        if (looksInlineEvidence(value)) return .{ .bytes = value, .source_kind = primary };
        const bytes = try a.workspace.readFileAlloc(a.io, value, max_evidence_bytes);
        return .{ .bytes = bytes, .source_kind = "workspace_file", .path = value, .owned = bytes, .owned_allocator = a.workspace.allocator };
    }
    if (path_field) |field| if (argString(args, field)) |path| {
        const bytes = try a.workspace.readFileAlloc(a.io, path, max_evidence_bytes);
        return .{ .bytes = bytes, .source_kind = "workspace_file", .path = path, .owned = bytes, .owned_allocator = a.workspace.allocator };
    };
    if (!required) return .{ .bytes = "", .source_kind = "missing" };
    return error.MissingArgument;
}

/// Implements evidence input error workflow logic using caller-owned inputs.
fn evidenceInputError(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, args: ?std.json.Value, field: []const u8, err: anyerror) !Result {
    if (err == error.MissingArgument) return missingArgumentResult(allocator, tool_name, field, "inline evidence content or workspace evidence path");
    const path = argString(args, field) orelse argString(args, "path") orelse field;
    return workspacePathErrorResult(a, allocator, tool_name, path, err);
}

/// Reports whether inline evidence matches the caller-provided data.
fn looksInlineEvidence(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    return trimmed.len == 0 or trimmed[0] == '{' or trimmed[0] == '[' or std.mem.indexOfScalar(u8, trimmed, '\n') != null or std.mem.indexOf(u8, trimmed, "==") != null or std.mem.indexOf(u8, trimmed, "panic") != null;
}

/// Serializes frame array fields into an allocator-owned JSON value; allocation failures propagate.
fn frameArrayValue(allocator: std.mem.Allocator, frames: []const diagnostic_stack.Frame) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (frames) |frame| try array.append(try frameValue(allocator, frame));
    return .{ .array = array };
}

/// Serializes frame fields into an allocator-owned JSON value; allocation failures propagate.
fn frameValue(allocator: std.mem.Allocator, frame: diagnostic_stack.Frame) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "index", .{ .integer = @intCast(frame.index) });
    try obj.put(allocator, "raw", .{ .string = try allocator.dupe(u8, frame.raw) });
    try obj.put(allocator, "symbol", .{ .string = try allocator.dupe(u8, frame.symbol) });
    try obj.put(allocator, "location", .{ .string = try allocator.dupe(u8, frame.location) });
    return .{ .object = obj };
}

/// Serializes top frame fields into an allocator-owned JSON value; allocation failures propagate.
fn topFrameValue(allocator: std.mem.Allocator, frames: diagnostic_stack.ParsedFrames) !std.json.Value {
    const top = frames.top() orelse return .null;
    return frameValue(allocator, top);
}

/// Serializes memory findings fields into an allocator-owned JSON value; allocation failures propagate.
fn memoryFindingsValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "failure_kind", .{ .string = diagnostic_crash.classifyFailure(text).name() });
    try obj.put(allocator, "definitely_lost_bytes", .{ .integer = parseMetricBefore(text, "bytes in", "definitely lost") orelse 0 });
    try obj.put(allocator, "error_count", .{ .integer = parseMetricBefore(text, "errors from", "ERROR SUMMARY") orelse 0 });
    try obj.put(allocator, "allocation_count", .{ .integer = parseMetricBefore(text, "allocations", "alloc") orelse 0 });
    try obj.put(allocator, "hotspot_count", .{ .integer = @intCast(countNeedle(text, "alloc")) });
    return .{ .object = obj };
}

/// Parses metric before input using caller-provided storage; malformed input and allocation failures propagate.
fn parseMetricBefore(text: []const u8, number_context: []const u8, line_context: []const u8) ?i64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, line_context) == null) continue;
        if (std.mem.indexOf(u8, line, number_context) == null and !std.mem.eql(u8, line_context, "ERROR SUMMARY")) continue;
        return firstInteger(stripValgrindPrefix(line));
    }
    return null;
}

/// Implements strip valgrind prefix workflow logic using caller-owned inputs.
fn stripValgrindPrefix(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, trimmed, "==")) return line;
    const end = std.mem.indexOfPos(u8, trimmed, 2, "==") orelse return line;
    return trimmed[end + 2 ..];
}

/// Implements first integer workflow logic using caller-owned inputs.
fn firstInteger(line: []const u8) ?i64 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (std.ascii.isDigit(line[i])) {
            const start = i;
            while (i < line.len and (std.ascii.isDigit(line[i]) or line[i] == ',')) i += 1;
            var digits: [64]u8 = undefined;
            var len: usize = 0;
            for (line[start..i]) |ch| if (ch != ',' and len < digits.len) {
                digits[len] = ch;
                len += 1;
            };
            return std.fmt.parseInt(i64, digits[0..len], 10) catch null;
        }
    }
    return null;
}

/// Serializes callgrind events fields into an allocator-owned JSON value; allocation failures propagate.
fn callgrindEventsValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var events = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "events:")) {
            var tokens = std.mem.tokenizeAny(u8, line["events:".len..], " \t");
            while (tokens.next()) |event| try events.append(.{ .string = try allocator.dupe(u8, event) });
            break;
        }
    }
    return .{ .array = events };
}

/// Serializes callgrind hotspots fields into an allocator-owned JSON value; allocation failures propagate.
fn callgrindHotspotsValue(allocator: std.mem.Allocator, text: []const u8, limit: usize) !std.json.Value {
    var items = std.json.Array.init(allocator);
    var current_fn: []const u8 = "";
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "fn=")) current_fn = line["fn=".len..];
        if (items.items.len >= limit) continue;
        if (line.len > 0 and std.ascii.isDigit(line[0])) {
            var parts = std.mem.tokenizeAny(u8, line, " \t");
            const line_no = parts.next() orelse continue;
            const cost = parts.next() orelse continue;
            var obj = std.json.ObjectMap.empty;
            try obj.put(allocator, "function", .{ .string = try allocator.dupe(u8, current_fn) });
            try obj.put(allocator, "line", .{ .string = try allocator.dupe(u8, line_no) });
            try obj.put(allocator, "cost", .{ .string = try allocator.dupe(u8, cost) });
            try items.append(.{ .object = obj });
        }
    }
    return .{ .array = items };
}

/// Serializes corpus summary fields into an allocator-owned JSON value; allocation failures propagate.
fn corpusSummaryValue(allocator: std.mem.Allocator, a: *App, path: []const u8, limit: usize) !std.json.Value {
    const scan = try a.workspace.scanDirectory(allocator, path, null);
    defer scan.deinit(allocator);
    var files = std.json.Array.init(allocator);
    var count: usize = 0;
    var total_bytes: usize = 0;
    for (scan.entries) |entry| {
        count += 1;
        if (files.items.len >= limit) continue;
        const joined = try std.fs.path.join(allocator, &.{ path, entry.path });
        const bytes = a.workspace.readFileAlloc(a.io, joined, 1024 * 1024) catch null;
        const file_bytes: usize = if (bytes) |owned| owned.len else 0;
        if (bytes) |owned| {
            total_bytes += file_bytes;
            a.workspace.allocator.free(owned);
        }
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "path", .{ .string = joined });
        try obj.put(allocator, "bytes", .{ .integer = @intCast(file_bytes) });
        try files.append(.{ .object = obj });
    }
    var obj = try baseValue(allocator, a, "zig_fuzz_corpus_summary", "Fuzz corpus summary", "high", &.{
        "Corpus identity is bounded to files listed in this result; large corpora may be truncated by limit.",
    });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "file_count", .{ .integer = @intCast(count) });
    try obj.put(allocator, "sampled_file_count", .{ .integer = @intCast(files.items.len) });
    try obj.put(allocator, "sampled_bytes", .{ .integer = @intCast(total_bytes) });
    try obj.put(allocator, "files", .{ .array = files });
    return .{ .object = obj };
}

/// Implements binary info workflow logic using caller-owned inputs.
fn binaryInfo(a: *App, allocator: std.mem.Allocator, path: []const u8) !BinaryInfo {
    const abs = try a.workspace.resolve(path);
    defer a.workspace.allocator.free(abs);
    const bytes = try a.workspace.readFileAlloc(a.io, path, max_binary_bytes);
    defer a.workspace.allocator.free(bytes);
    return .{
        .path = try allocator.dupe(u8, path),
        .abs_path = try allocator.dupe(u8, abs),
        .bytes_len = bytes.len,
        .sha256 = try artifacts.sha256Hex(allocator, bytes),
        .format = try allocator.dupe(u8, sniffBinaryFormat(bytes)),
        .stripped_hint = try allocator.dupe(u8, if (std.mem.indexOf(u8, bytes, ".debug") != null) "debug_sections_seen" else "debug_sections_not_seen"),
    };
}

/// Implements sniff binary format workflow logic using caller-owned inputs.
fn sniffBinaryFormat(bytes: []const u8) []const u8 {
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "\x7fELF")) return "elf";
    if (bytes.len >= 4 and (std.mem.eql(u8, bytes[0..4], "\xcf\xfa\xed\xfe") or std.mem.eql(u8, bytes[0..4], "\xca\xfe\xba\xbe"))) return "macho";
    if (bytes.len >= 2 and std.mem.eql(u8, bytes[0..2], "MZ")) return "pe";
    if (bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "\x00asm")) return "wasm";
    return "unknown";
}

/// Implements put binary info workflow logic using caller-owned inputs.
fn putBinaryInfo(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, info: BinaryInfo) !void {
    try obj.put(allocator, "binary_identity", try binaryInfoValue(allocator, info));
    try obj.put(allocator, "binary_identity_id", try identityFromText(allocator, info.sha256, "binary"));
    try obj.put(allocator, "format", .{ .string = info.format });
    try obj.put(allocator, "size_bytes", .{ .integer = @intCast(info.bytes_len) });
    try obj.put(allocator, "stripped_hint", .{ .string = info.stripped_hint });
}

/// Serializes binary info fields into an allocator-owned JSON value; allocation failures propagate.
fn binaryInfoValue(allocator: std.mem.Allocator, info: BinaryInfo) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", .{ .string = info.path });
    try obj.put(allocator, "abs_path", .{ .string = info.abs_path });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(info.bytes_len) });
    try obj.put(allocator, "sha256", .{ .string = info.sha256 });
    try obj.put(allocator, "format", .{ .string = info.format });
    try obj.put(allocator, "stripped_hint", .{ .string = info.stripped_hint });
    return .{ .object = obj };
}

/// Serializes section summary fields into an allocator-owned JSON value; allocation failures propagate.
fn sectionSummaryValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var sections = std.json.Array.init(allocator);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (sections.items.len >= 40) continue;
        if (!std.mem.startsWith(u8, trimmed, ".") and std.mem.indexOf(u8, trimmed, " .") == null) continue;
        var obj = std.json.ObjectMap.empty;
        try obj.put(allocator, "raw", .{ .string = try allocator.dupe(u8, trimmed) });
        try sections.append(.{ .object = obj });
    }
    return .{ .array = sections };
}

/// Serializes symbol summary fields into an allocator-owned JSON value; allocation failures propagate.
fn symbolSummaryValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "exported_symbol_count", .{ .integer = @intCast(countNeedle(text, " g ")) });
    try obj.put(allocator, "undefined_symbol_count", .{ .integer = @intCast(countNeedle(text, "*UND*")) });
    try obj.put(allocator, "debug_symbol_hint", .{ .bool = std.mem.indexOf(u8, text, ".debug") != null });
    return .{ .object = obj };
}

/// Serializes target plan fields into an allocator-owned JSON value; allocation failures propagate.
fn targetPlanValue(allocator: std.mem.Allocator, target: []const u8, command_text: ?[]const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "target", .{ .string = try allocator.dupe(u8, target) });
    try obj.put(allocator, "runtime_class", .{ .string = runtimeClass(target) });
    try obj.put(allocator, "emulator", .{ .string = qemuDefaultForTarget(target) });
    try obj.put(allocator, "command", stringOrNull(command_text));
    try obj.put(allocator, "supported_by_zigar", .{ .bool = !std.mem.eql(u8, runtimeClass(target), "unknown") });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, &.{"Target planning does not prove the binary can execute under the selected emulator."}));
    return .{ .object = obj };
}

/// Invokes runtime class with caller-owned inputs; command and allocation failures propagate.
fn runtimeClass(target: []const u8) []const u8 {
    if (std.mem.indexOf(u8, target, "wasm") != null) return "wasm";
    if (std.mem.indexOf(u8, target, "freestanding") != null or std.mem.indexOf(u8, target, "none") != null) return "bare_metal";
    if (std.mem.indexOf(u8, target, "linux") != null or std.mem.indexOf(u8, target, "native") != null) return "host_or_emulated_os";
    if (std.mem.indexOf(u8, target, "windows") != null or std.mem.indexOf(u8, target, "macos") != null) return "host_os_specific";
    return "unknown";
}

/// Implements qemu default for target workflow logic using caller-owned inputs.
fn qemuDefaultForTarget(target: []const u8) []const u8 {
    if (std.mem.indexOf(u8, target, "aarch64") != null) return "qemu-aarch64";
    if (std.mem.indexOf(u8, target, "arm") != null) return "qemu-arm";
    if (std.mem.indexOf(u8, target, "riscv64") != null) return "qemu-riscv64";
    if (std.mem.indexOf(u8, target, "riscv32") != null) return "qemu-riscv32";
    if (std.mem.indexOf(u8, target, "x86_64") != null) return "qemu-x86_64";
    return "qemu-system";
}

/// Serializes embedded detect fields into an allocator-owned JSON value; allocation failures propagate.
fn embeddedDetectValue(allocator: std.mem.Allocator, a: *App, limit: usize) !std.json.Value {
    var signals = std.json.Array.init(allocator);
    const scan = try a.workspace.scanDirectory(allocator, ".", null);
    defer scan.deinit(allocator);
    var seen: usize = 0;
    for (scan.entries) |entry| {
        if (seen >= limit) break;
        if (zig_analysis.skipWorkspacePath(entry.path)) continue;
        if (!looksEmbeddedPath(entry.path)) continue;
        const bytes = a.workspace.readFileAlloc(a.io, entry.path, 256 * 1024) catch continue;
        defer a.workspace.allocator.free(bytes);
        if (!containsAny(bytes, &.{ "microzig", "MicroZig", "flash", "linker", "memory", "cortex_m", "rp2040", "stm32", "nrf52" }) and !looksEmbeddedPath(entry.path)) continue;
        seen += 1;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "path", .{ .string = try allocator.dupe(u8, entry.path) });
        try item.put(allocator, "signal", .{ .string = embeddedSignal(entry.path, bytes) });
        try item.put(allocator, "line", .{ .integer = @intCast(lineNumberLocal(bytes, firstEmbeddedSignalIndex(bytes))) });
        try signals.append(.{ .object = item });
    }
    var obj = try baseValue(allocator, a, "zig_embedded_detect", "Embedded Zig workspace detection", "medium", &.{
        "Detection is heuristic and should be confirmed against build.zig, board packages, and hardware docs.",
    });
    try obj.put(allocator, "signals", .{ .array = signals });
    try obj.put(allocator, "signal_count", .{ .integer = @intCast(signals.items.len) });
    try obj.put(allocator, "embedded_status", .{ .string = if (signals.items.len > 0) "signals_found" else "no_static_signals" });
    return .{ .object = obj };
}

/// Reports whether embedded path matches the caller-provided data.
fn looksEmbeddedPath(path: []const u8) bool {
    return containsAny(path, &.{ "microzig", "board", "boards", "linker", ".ld", "memory", "firmware", "flash", "openocd" });
}

/// Implements embedded signal workflow logic using caller-owned inputs.
fn embeddedSignal(path: []const u8, bytes: []const u8) []const u8 {
    if (containsAny(bytes, &.{ "microzig", "MicroZig" })) return "microzig";
    if (containsAny(path, &.{ ".ld", "linker" })) return "linker_script";
    if (containsAny(bytes, &.{ "rp2040", "stm32", "nrf52", "cortex_m" })) return "board_or_mcu";
    if (containsAny(bytes, &.{ "flash", "openocd", "probe-rs" })) return "flash_workflow";
    return "embedded_path";
}

/// Implements first embedded signal index workflow logic using caller-owned inputs.
fn firstEmbeddedSignalIndex(bytes: []const u8) usize {
    var best: ?usize = null;
    const needles = [_][]const u8{ "microzig", "MicroZig", "flash", "linker", "rp2040", "stm32", "nrf52", "cortex_m" };
    for (&needles) |needle| {
        if (std.mem.indexOf(u8, bytes, needle)) |idx| best = if (best) |b| @min(b, idx) else idx;
    }
    return best orelse 0;
}

/// Implements board target workflow logic using caller-owned inputs.
fn boardTarget(board: []const u8) []const u8 {
    if (containsAny(board, &.{ "rp2040", "pico" })) return "thumb-freestanding-eabi";
    if (containsAny(board, &.{ "stm32", "nrf", "cortex" })) return "thumb-freestanding-eabi";
    if (containsAny(board, &.{"esp32"})) return "xtensa-freestanding-none";
    return "project_defined";
}

/// Reports whether cortex board matches the caller-provided data.
fn isCortexBoard(board: []const u8) bool {
    return containsAny(board, &.{ "rp2040", "pico", "stm32", "nrf", "cortex" });
}

/// Implements flash command workflow logic using caller-owned inputs.
fn flashCommand(allocator: std.mem.Allocator, flash_tool: []const u8, board: ?[]const u8, image: ?[]const u8) ![]const u8 {
    if (std.mem.indexOf(u8, flash_tool, "probe-rs") != null) {
        return std.fmt.allocPrint(allocator, "{s} download --chip {s} {s}", .{ flash_tool, board orelse "<chip>", image orelse "<firmware>" });
    }
    if (std.mem.indexOf(u8, flash_tool, "openocd") != null) {
        return std.fmt.allocPrint(allocator, "{s} -f <interface.cfg> -f <target.cfg> -c 'program {s} verify reset exit'", .{ flash_tool, image orelse "<firmware>" });
    }
    return std.fmt.allocPrint(allocator, "{s} <flash args for {s}> {s}", .{ flash_tool, board orelse "<board>", image orelse "<firmware>" });
}

/// Serializes base fields into an allocator-owned JSON value; allocation failures propagate.
fn baseValue(allocator: std.mem.Allocator, a: *App, kind: []const u8, evidence_basis: []const u8, confidence: []const u8, limitations: []const []const u8) !std.json.ObjectMap {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = kind });
    try obj.put(allocator, "schema_version", .{ .integer = schema_version });
    try obj.put(allocator, "evidence_basis", .{ .string = evidence_basis });
    try obj.put(allocator, "backend_status", try backendStatusValue(allocator, "not_required", true, "not_used", "No external backend is required for this operation.", ""));
    try obj.put(allocator, "command_argv", try argvValue(allocator, &.{}));
    try obj.put(allocator, "platform", try platformValue(allocator, a));
    try obj.put(allocator, "toolchain", try toolchainValue(allocator, a));
    try obj.put(allocator, "target", .null);
    try obj.put(allocator, "artifact_identity", .null);
    try obj.put(allocator, "preimage_identity", .null);
    try obj.put(allocator, "crash_identity", .null);
    try obj.put(allocator, "confidence", .{ .string = confidence });
    try obj.put(allocator, "limitations", try stringArrayValue(allocator, limitations));
    try obj.put(allocator, "skipped_validation", try stringArrayValue(allocator, &.{}));
    return obj;
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

/// Serializes platform fields into an allocator-owned JSON value; allocation failures propagate.
fn platformValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "os", .{ .string = a.context.platform.os });
    try obj.put(allocator, "arch", .{ .string = a.context.platform.arch });
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

/// Implements unsupported backend result workflow logic using caller-owned inputs.
fn unsupportedBackendResult(a: *App, allocator: std.mem.Allocator, backend: []const u8, operation: []const u8, resolution: []const u8) !Result {
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "kind", .{ .string = "backend_error" });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "backend", .{ .string = backend });
    try obj.put(allocator, "operation", .{ .string = operation });
    try obj.put(allocator, "error", .{ .string = "UnsupportedPlatform" });
    try obj.put(allocator, "error_kind", .{ .string = "unsupported_platform" });
    try obj.put(allocator, "platform", try platformValue(allocator, a));
    try obj.put(allocator, "resolution", .{ .string = resolution });
    return structured(allocator, .{ .object = obj });
}

/// Writes evidence artifact fields to the provided JSON stream and propagates writer failures.
fn writeEvidenceArtifact(a: *App, allocator: std.mem.Allocator, path: []const u8, value: std.json.Value, producer: []const u8, artifact_kind: []const u8, argv: []const []const u8, backend: []const u8, target: []const u8, notes: []const u8) !void {
    const bytes = try serializeAlloc(allocator, value);
    try a.workspace.putFile(path, bytes);
    const resolved_abs = try a.workspace.resolveOutput(path);
    defer a.workspace.allocator.free(resolved_abs);
    const identity = try artifacts.identityFromBytes(allocator, path, try allocator.dupe(u8, resolved_abs), bytes);
    try recordWrittenArtifact(a, allocator, .{
        .identity = identity,
        .provenance = .{
            .producer = producer,
            .artifact_kind = artifact_kind,
            .command_argv = argv,
            .backend_name = backend,
            .target = target,
            .notes = notes,
            .toolchain = toolchainProvenance(a),
        },
        .indexed_at_unix_ms = unixMs(a),
    }, bytes);
}

/// Serializes artifact identity fields into an allocator-owned JSON value; allocation failures propagate.
fn artifactIdentityValue(allocator: std.mem.Allocator, a: *App, path: []const u8, bytes: []const u8) !std.json.Value {
    const resolved_abs = try a.workspace.resolveOutput(path);
    defer a.workspace.allocator.free(resolved_abs);
    const identity = try artifacts.identityFromBytes(allocator, path, try allocator.dupe(u8, resolved_abs), bytes);
    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "abs_path", .{ .string = identity.abs_path });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(identity.bytes) });
    try obj.put(allocator, "sha256", .{ .string = identity.sha256 });
    return .{ .object = obj };
}

/// Builds preimage identity metadata for the requested workspace path.
fn preimageIdentityForPath(a: *App, allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    const bytes = a.workspace.readFileAlloc(a.io, path, max_evidence_bytes) catch |err| switch (err) {
        error.FileNotFound => return preimageValue(allocator, false, 0, ""),
        else => return err,
    };
    defer a.workspace.allocator.free(bytes);
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

/// Implements identity from text workflow logic using caller-owned inputs.
fn identityFromText(allocator: std.mem.Allocator, text: []const u8, prefix: []const u8) !std.json.Value {
    const hash = try artifacts.sha256Hex(allocator, text);
    return .{ .string = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ prefix, hash[0..@min(16, hash.len)] }) };
}

/// Implements concat argv workflow logic using caller-owned inputs.
fn concatArgv(allocator: std.mem.Allocator, prefix: []const []const u8, rest: []const []const u8) ![]const []const u8 {
    var list = std.ArrayList([]const u8).empty;
    try list.appendSlice(allocator, prefix);
    try list.appendSlice(allocator, rest);
    return list.items;
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

/// Implements pct delta workflow logic using caller-owned inputs.
fn pctDelta(before: usize, after: usize) f64 {
    if (before == 0) return 0;
    return ((@as(f64, @floatFromInt(after)) - @as(f64, @floatFromInt(before))) / @as(f64, @floatFromInt(before))) * 100.0;
}

/// Implements count needle workflow logic using caller-owned inputs.
fn countNeedle(text: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var rest = text;
    while (std.mem.indexOf(u8, rest, needle)) |idx| {
        count += 1;
        rest = rest[idx + needle.len ..];
    }
    return count;
}

/// Reports whether any matches the caller-provided data.
fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    return false;
}

/// Releases argv allocations; callers must not reuse freed items.
fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

const fakes = @import("../../../testing/fakes/root.zig");
const test_ports = @import("../../ports.zig");

test "diagnostics plans cover backend probes previews and unsupported apply gates" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const result_allocator = result_arena.allocator();

    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var probe = fakes.FakeBackendProbe.init(std.testing.allocator);
    defer probe.deinit();

    try probe.expectCheck(.{
        .backend = "lldb",
        .argv = &.{ "/usr/bin/lldb", "--version" },
        .cwd = "/repo",
        .timeout_ms = 5000,
        .provenance = "arch110-workflow-backend-check",
    }, .{
        .backend = "lldb",
        .available = true,
        .version = "lldb-19",
        .basis = "fake lldb",
    });
    try probe.expectCheck(.{
        .backend = "probe-rs",
        .argv = &.{ "probe-rs", "--help" },
        .cwd = "/repo",
        .timeout_ms = 5000,
        .provenance = "arch110-workflow-backend-check",
    }, .{
        .backend = "probe-rs",
        .available = false,
        .unavailable_reason = "not installed",
        .basis = "PATH probe",
    });

    try workspace.expectResolve(.{
        .path = "out/heaptrack.gz",
        .for_output = true,
        .provenance = "arch110-workflow-resolve-output",
    }, "/repo/out/heaptrack.gz");
    try workspace.expectResolve(.{
        .path = "corpus",
        .provenance = "arch110-workflow-resolve",
    }, "/repo/corpus");
    try workspace.expectResolve(.{
        .path = "out/afl",
        .for_output = true,
        .provenance = "arch110-workflow-resolve-output",
    }, "/repo/out/afl");
    try workspace.expectResolve(.{
        .path = "out/callgrind.out",
        .for_output = true,
        .provenance = "arch110-workflow-resolve-output",
    }, "/repo/out/callgrind.out");
    try workspace.expectReadError(.{
        .path = "out/callgrind.out",
        .max_bytes = max_evidence_bytes,
        .provenance = "arch110-workflow-read",
    }, error.FileNotFound);

    var app = diagnosticsTestApp(result_allocator, workspace.port(), scanner.port(), commands.port(), probe.port(), null, .{
        .os = "macos",
        .arch = "aarch64",
        .is_windows = true,
        .is_linux = false,
    });

    const debug_args = try parseTestArgs(result_allocator,
        \\{"probe_backend":true,"lldb_path":"/usr/bin/lldb","binary":"zig-out/bin/app","core":"core.1","command":"zig test","target":"native"}
    );
    const debug_plan = try zigDebugPlan(&app, result_allocator, debug_args.value);
    try expectKind(debug_plan, "zig_debug_plan");
    try expectNestedString(debug_plan, "backend_status", "status", "ok");

    const flash_args = try parseTestArgs(result_allocator,
        \\{"probe_backend":true,"flash_tool":"probe-rs","board":"rp2040","image":"zig-out/firmware.uf2"}
    );
    const flash_plan = try zigFlashPlan(&app, result_allocator, flash_args.value);
    try expectKind(flash_plan, "zig_flash_plan");
    try expectNestedString(flash_plan, "backend_status", "status", "not installed");

    const heap_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"command":"zig build run","output":"out/heaptrack.gz"}
    );
    const heaptrack = try zigHeaptrackRun(&app, result_allocator, heap_args.value);
    try expectBackendError(heaptrack, "heaptrack", "unsupported_platform");

    const valgrind_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"command":"zig build test"}
    );
    const memcheck = try zigValgrindMemcheck(&app, result_allocator, valgrind_args.value);
    try expectBackendError(memcheck, "valgrind", "unsupported_platform");

    const afl_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"command":"./fuzz","corpus":"corpus","output":"out/afl"}
    );
    const afl = try zigAflRun(&app, result_allocator, afl_args.value);
    try expectBackendError(afl, "afl-fuzz", "unsupported_platform");

    const qemu_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"target":"x86_64-linux","command":"zig-out/bin/test"}
    );
    const qemu = try zigQemuTest(&app, result_allocator, qemu_args.value);
    try expectBackendError(qemu, "qemu", "unsupported_platform");

    const callgrind_args = try parseTestArgs(result_allocator,
        \\{"command":"zig build run","output":"out/callgrind.out","target":"native"}
    );
    const callgrind = try zigCallgrindReport(&app, result_allocator, callgrind_args.value);
    try expectKind(callgrind, "zig_callgrind_report");
    try std.testing.expect(!callgrind.value.object.get("applied").?.bool);

    try workspace.verify();
    try scanner.verify();
    try commands.verify();
    try probe.verify();
}

test "diagnostics evidence readers cover inline path missing and summary parsers" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const result_allocator = result_arena.allocator();

    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();

    try workspace.expectRead(.{
        .path = "asan.log",
        .max_bytes = max_evidence_bytes,
        .provenance = "arch110-workflow-read",
    },
        \\==1==ERROR: AddressSanitizer: heap-use-after-free
        \\    #0 0x1 in main src/main.zig:10
    );
    try workspace.expectRead(.{
        .path = "valgrind.txt",
        .max_bytes = max_evidence_bytes,
        .provenance = "arch110-workflow-read",
    },
        \\==1== 1,024 bytes in 2 blocks are definitely lost
        \\==1== ERROR SUMMARY: 3 errors from 3 contexts
        \\allocations: 42 allocs
    );

    var app = diagnosticsTestApp(result_allocator, workspace.port(), scanner.port(), commands.port(), null, null, .{});

    const frame_args = try parseTestArgs(result_allocator,
        \\{"text":"frame #0: 0x0001 app`main at src/main.zig:4\nframe #1: start","limit":2}
    );
    const frames = try zigDebugFrameSummary(&app, result_allocator, frame_args.value);
    try expectKind(frames, "zig_debug_frame_summary");
    try std.testing.expectEqual(@as(i64, 2), frames.value.object.get("frame_count").?.integer);

    const sanitizer_args = try parseTestArgs(result_allocator,
        \\{"path":"asan.log","command":"zig test"}
    );
    const sanitizer = try zigSanitizerFusion(&app, result_allocator, sanitizer_args.value);
    try expectKind(sanitizer, "zig_sanitizer_fusion");
    try expectStringField(sanitizer, "source_kind", "workspace_file");

    const missing_args = try parseTestArgs(result_allocator, "{}");
    const panic_missing = try zigPanicTraceAnalyze(&app, result_allocator, missing_args.value);
    try std.testing.expect(panic_missing.is_error);
    try expectKind(panic_missing, "argument_error");

    const repro = try zigCrashReproPlan(&app, result_allocator, missing_args.value);
    try expectKind(repro, "zig_crash_repro_plan");
    try expectStringField(repro, "failure_kind", "unknown");

    const heap_summary_args = try parseTestArgs(result_allocator,
        \\{"text":"valgrind.txt"}
    );
    const heap_summary = try zigHeaptrackSummary(&app, result_allocator, heap_summary_args.value);
    try expectKind(heap_summary, "zig_heaptrack_summary");
    try std.testing.expectEqual(@as(i64, 1024), heap_summary.value.object.get("findings").?.object.get("definitely_lost_bytes").?.integer);

    const callgrind_args = try parseTestArgs(result_allocator,
        \\{"content":"events: Ir Dr\nfn=main\n42 100\nfn=worker\n45 8\n"}
    );
    const callgrind = try zigCallgrindReport(&app, result_allocator, callgrind_args.value);
    try expectKind(callgrind, "zig_callgrind_report");
    try std.testing.expectEqual(@as(usize, 2), callgrind.value.object.get("events").?.array.items.len);

    const minimize_args = try parseTestArgs(result_allocator,
        \\{"content":"panic: reached unreachable code","command":"./fuzz"}
    );
    const minimize = try zigFuzzCrashMinimize(&app, result_allocator, minimize_args.value);
    try expectKind(minimize, "zig_fuzz_crash_minimize");
    try std.testing.expect(minimize.value.object.get("crash_identity").? == .string);

    try workspace.verify();
    try scanner.verify();
    try commands.verify();
}

test "diagnostics apply paths write artifacts and parse binary backend output" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const result_allocator = result_arena.allocator();

    var workspace = RecordingWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    try workspace.putFixture("bin/app", "\x7fELF.debug_info symbol-bytes");
    try workspace.putFixture("out/existing.json", "old artifact");
    try workspace.putScanEntries(&.{ "seed-a", "seed-b", "ignored-large" });

    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var probe = fakes.FakeBackendProbe.init(std.testing.allocator);
    defer probe.deinit();
    var artifact_store = RecordingArtifactStore.init(std.testing.allocator);
    defer artifact_store.deinit();
    var clock = fakes.FakeClockAndIds.init(std.testing.allocator);
    defer clock.deinit();

    try commands.expectRun(.{
        .argv = &.{ "./fuzz", "-runs=1" },
        .cwd = "/repo",
        .timeout_ms = 30000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 0,
        .stdout = "done",
        .stderr = "",
        .duration_ms = 11,
        .provenance = "fake",
    });
    try probe.expectCheck(.{
        .backend = "llvm-objdump",
        .argv = &.{ "llvm-objdump", "--version" },
        .cwd = "/repo",
        .timeout_ms = 5000,
        .provenance = "arch110-workflow-backend-check",
    }, .{
        .backend = "llvm-objdump",
        .available = true,
        .version = "19.1.0",
        .basis = "fake objdump",
    });
    try commands.expectRun(.{
        .argv = &.{ "llvm-objdump", "-h", "-t", "/repo/bin/app" },
        .cwd = "/repo",
        .timeout_ms = 30000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 0,
        .stdout =
        \\Sections:
        \\  1 .text 0004
        \\  2 .debug_info 0008
        \\00000000 g F .text main
        \\*UND* external
        ,
        .stderr = "",
        .duration_ms = 7,
        .provenance = "fake",
    });

    var app = diagnosticsTestApp(result_allocator, workspace.port(), scanner.port(), commands.port(), probe.port(), artifact_store.port(), .{
        .os = "linux",
        .arch = "x86_64",
        .is_linux = true,
    });
    app.context.clock_and_ids = clock.port();

    const fuzz_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"command":"./fuzz -runs=1","output":"out/existing.json","target":"native"}
    );
    const fuzz_run = try zigLibfuzzerRun(&app, result_allocator, fuzz_args.value);
    try expectKind(fuzz_run, "zig_libfuzzer_run");
    try std.testing.expect(fuzz_run.value.object.get("applied").?.bool);
    try std.testing.expect(fuzz_run.value.object.get("preimage_identity").?.object.get("exists").?.bool);
    try std.testing.expectEqual(@as(usize, 1), workspace.write_records.items.len);
    try std.testing.expectEqual(@as(usize, 1), artifact_store.records.items.len);

    const objdump_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"path":"bin/app"}
    );
    const objdump = try zigObjdumpSummary(&app, result_allocator, objdump_args.value);
    try expectKind(objdump, "zig_objdump_summary");
    try expectStringField(objdump, "format", "elf");
    try expectStringField(objdump, "debug_info_status", "debug_info_seen");
    try std.testing.expectEqual(@as(i64, 1), objdump.value.object.get("symbols").?.object.get("exported_symbol_count").?.integer);

    const corpus_args = try parseTestArgs(result_allocator,
        \\{"path":"corpus","limit":2}
    );
    const corpus = try zigFuzzCorpusSummary(&app, result_allocator, corpus_args.value);
    try expectKind(corpus, "zig_fuzz_corpus_summary");
    try std.testing.expectEqual(@as(i64, 3), corpus.value.object.get("file_count").?.integer);
    try std.testing.expectEqual(@as(i64, 2), corpus.value.object.get("sampled_file_count").?.integer);

    try commands.verify();
    try probe.verify();
    try scanner.verify();
}

test "diagnostics backend apply paths cover success unavailable and command errors" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const result_allocator = result_arena.allocator();

    var workspace = RecordingWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    try workspace.putFixture("bin/app", "\x7fELF.debug_info");

    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var probe = fakes.FakeBackendProbe.init(std.testing.allocator);
    defer probe.deinit();
    var artifact_store = RecordingArtifactStore.init(std.testing.allocator);
    defer artifact_store.deinit();

    try std.testing.expectError(error.UnexpectedCall, artifact_store.port().put(std.testing.allocator, .{
        .namespace = "diagnostics",
        .name = "unused",
        .kind = "json",
        .bytes = "{}",
    }));
    try std.testing.expectError(error.UnexpectedCall, artifact_store.port().read(std.testing.allocator, .{ .id = "missing" }));

    try probe.expectCheck(.{
        .backend = "heaptrack",
        .argv = &.{ "heaptrack", "--help" },
        .cwd = "/repo",
        .timeout_ms = 5000,
        .provenance = "arch110-workflow-backend-check",
    }, .{
        .backend = "heaptrack",
        .available = true,
        .version = "heaptrack-1",
        .basis = "fake heaptrack",
    });
    try commands.expectRun(.{
        .argv = &.{ "heaptrack", "-o", "/repo/out/heaptrack.gz", "--", "./app" },
        .cwd = "/repo",
        .timeout_ms = 30000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 0,
        .stdout = "",
        .stderr =
        \\==1== 64 bytes in 1 blocks are definitely lost
        \\==1== ERROR SUMMARY: 0 errors from 0 contexts
        ,
        .duration_ms = 12,
        .provenance = "fake",
    });
    try probe.expectCheck(unavailableProbe("valgrind", &.{ "valgrind", "--version" }), .{
        .backend = "valgrind",
        .available = false,
        .unavailable_reason = "missing",
        .basis = "PATH probe",
    });
    try probe.expectCheck(unavailableProbe("valgrind", &.{ "valgrind", "--version" }), .{
        .backend = "valgrind",
        .available = false,
        .unavailable_reason = "missing",
        .basis = "PATH probe",
    });
    try probe.expectCheck(unavailableProbe("afl-fuzz", &.{ "afl-fuzz", "-h" }), .{
        .backend = "afl-fuzz",
        .available = false,
        .unavailable_reason = "missing",
        .basis = "PATH probe",
    });
    try probe.expectCheck(unavailableProbe("qemu", &.{ "qemu-riscv64", "--version" }), .{
        .backend = "qemu",
        .available = false,
        .unavailable_reason = "missing",
        .basis = "PATH probe",
    });
    try probe.expectCheck(.{
        .backend = "lldb",
        .argv = &.{ "lldb", "--version" },
        .cwd = "/repo",
        .timeout_ms = 5000,
        .provenance = "arch110-workflow-backend-check",
    }, .{
        .backend = "lldb",
        .available = true,
        .version = "lldb-19",
        .basis = "fake lldb",
    });
    try commands.expectRun(.{
        .argv = &.{ "lldb", "--batch", "-o", "bt all", "/repo/bin/app" },
        .cwd = "/repo",
        .timeout_ms = 30000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 0,
        .stdout =
        \\frame #0: 0x0001 app`main at src/main.zig:4
        ,
        .stderr = "",
        .duration_ms = 4,
        .provenance = "fake",
    });
    try probe.expectCheck(.{
        .backend = "lldb",
        .argv = &.{ "lldb", "--version" },
        .cwd = "/repo",
        .timeout_ms = 5000,
        .provenance = "arch110-workflow-backend-check",
    }, .{
        .backend = "lldb",
        .available = false,
        .unavailable_reason = "not installed",
        .basis = "PATH probe",
    });
    try commands.expectRunError(.{
        .argv = &.{"./fail"},
        .cwd = "/repo",
        .timeout_ms = 30000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, error.AccessDenied);

    var app = diagnosticsTestApp(result_allocator, workspace.port(), scanner.port(), commands.port(), probe.port(), artifact_store.port(), .{
        .os = "linux",
        .arch = "x86_64",
        .is_linux = true,
    });

    const heaptrack_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"command":"./app","output":"out/heaptrack.gz"}
    );
    const heaptrack = try zigHeaptrackRun(&app, result_allocator, heaptrack_args.value);
    try expectKind(heaptrack, "zig_heaptrack_run");
    try std.testing.expect(heaptrack.value.object.get("applied").?.bool);

    const valgrind_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"command":"./app"}
    );
    const valgrind = try zigValgrindMemcheck(&app, result_allocator, valgrind_args.value);
    try expectBackendError(valgrind, "valgrind", "unavailable");

    const callgrind_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"command":"./app","output":"out/callgrind.out"}
    );
    const callgrind = try zigCallgrindReport(&app, result_allocator, callgrind_args.value);
    try expectBackendError(callgrind, "valgrind", "unavailable");

    const afl_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"command":"./fuzz","corpus":"corpus","output":"out/afl"}
    );
    const afl = try zigAflRun(&app, result_allocator, afl_args.value);
    try expectBackendError(afl, "afl-fuzz", "unavailable");

    const qemu_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"target":"riscv64-linux","command":"guest"}
    );
    const qemu = try zigQemuTest(&app, result_allocator, qemu_args.value);
    try expectBackendError(qemu, "qemu", "unavailable");

    const lldb_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"binary":"bin/app","limit":1}
    );
    const lldb = try zigLldbBacktrace(&app, result_allocator, lldb_args.value);
    try expectKind(lldb, "zig_lldb_backtrace");
    try std.testing.expect(lldb.value.object.get("applied").?.bool);

    const core_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"core":"core.1"}
    );
    const core = try zigCoreInspect(&app, result_allocator, core_args.value);
    try expectBackendError(core, "lldb", "unavailable");

    const libfuzzer_args = try parseTestArgs(result_allocator,
        \\{"apply":true,"command":"./fail","output":"out/libfuzzer.json"}
    );
    const libfuzzer = try zigLibfuzzerRun(&app, result_allocator, libfuzzer_args.value);
    try expectKind(libfuzzer, "command_error");

    try std.testing.expectEqual(@as(usize, 1), artifact_store.records.items.len);
    try commands.verify();
    try probe.verify();
    try scanner.verify();
}

test "diagnostics evidence errors report workspace read failures from path-like text" {
    var result_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer result_arena.deinit();
    const result_allocator = result_arena.allocator();

    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();

    try workspace.expectReadError(.{
        .path = "logs/asan.txt",
        .max_bytes = max_evidence_bytes,
        .provenance = "arch110-workflow-read",
    }, error.FileNotFound);

    var app = diagnosticsTestApp(result_allocator, workspace.port(), scanner.port(), commands.port(), null, null, .{});
    const args = try parseTestArgs(result_allocator,
        \\{"text":"logs/asan.txt"}
    );
    const result = try zigSanitizerFusion(&app, result_allocator, args.value);
    try std.testing.expect(result.is_error);
    try expectKind(result, "workspace_path_error");

    try workspace.verify();
    try scanner.verify();
    try commands.verify();
}

test "diagnostics private helpers cover classifier and serializer edge cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expect(looksInlineEvidence(" \n"));
    try std.testing.expect(looksInlineEvidence("{\"panic\":true}"));
    try std.testing.expect(looksInlineEvidence("==1==ERROR"));
    try std.testing.expect(!looksInlineEvidence("logs/asan.txt"));
    try std.testing.expectEqual(@as(?i64, null), firstInteger("no digits here"));
    try std.testing.expectEqual(@as(?i64, 1234567), firstInteger("bytes 1,234,567 total"));
    try std.testing.expectEqualStrings(" 1,024 bytes", stripValgrindPrefix("==77== 1,024 bytes"));
    try std.testing.expectEqualStrings("==unterminated", stripValgrindPrefix("==unterminated"));

    const empty_events = try callgrindEventsValue(allocator, "fn=main\n1 2\n");
    try std.testing.expectEqual(@as(usize, 0), empty_events.array.items.len);
    const sections = try sectionSummaryValue(allocator, ".text 0004\nprefix .data 0002\nnot a section\n");
    try std.testing.expectEqual(@as(usize, 2), sections.array.items.len);
    const symbols = try symbolSummaryValue(allocator, "0000 g F .text main\n*UND* puts\n.debug_info\n");
    try std.testing.expectEqual(@as(i64, 1), symbols.object.get("exported_symbol_count").?.integer);
    try std.testing.expectEqual(@as(i64, 1), symbols.object.get("undefined_symbol_count").?.integer);
    try std.testing.expect(symbols.object.get("debug_symbol_hint").?.bool);

    try std.testing.expectEqualStrings("host_os_specific", runtimeClass("x86_64-windows"));
    try std.testing.expectEqualStrings("unknown", runtimeClass("mipsel-custom"));
    try std.testing.expectEqualStrings("qemu-aarch64", qemuDefaultForTarget("aarch64-linux"));
    try std.testing.expectEqualStrings("qemu-arm", qemuDefaultForTarget("arm-linux"));
    try std.testing.expectEqualStrings("qemu-riscv64", qemuDefaultForTarget("riscv64-linux"));
    try std.testing.expectEqualStrings("qemu-riscv32", qemuDefaultForTarget("riscv32-linux"));
    try std.testing.expectEqualStrings("qemu-x86_64", qemuDefaultForTarget("x86_64-linux"));
    try std.testing.expectEqualStrings("qemu-system", qemuDefaultForTarget("native"));

    try std.testing.expectEqualStrings("thumb-freestanding-eabi", boardTarget("stm32f4"));
    try std.testing.expectEqualStrings("xtensa-freestanding-none", boardTarget("esp32c3"));
    try std.testing.expectEqualStrings("project_defined", boardTarget("custom-board"));
    const openocd = try flashCommand(allocator, "openocd", null, "firmware.elf");
    try std.testing.expect(std.mem.indexOf(u8, openocd, "program firmware.elf") != null);
    const vendor = try flashCommand(allocator, "vendor-flash", null, null);
    try std.testing.expect(std.mem.indexOf(u8, vendor, "<board>") != null);

    try std.testing.expectEqualStrings("macho", sniffBinaryFormat("\xcf\xfa\xed\xfepayload"));
    try std.testing.expectEqualStrings("macho", sniffBinaryFormat("\xca\xfe\xba\xbepayload"));
    try std.testing.expectEqualStrings("pe", sniffBinaryFormat("MZpayload"));
    try std.testing.expectEqualStrings("wasm", sniffBinaryFormat("\x00asmpayload"));
    try std.testing.expectEqualStrings("unknown", sniffBinaryFormat("raw"));

    const pre_missing = try preimageValue(allocator, false, 0, "");
    try std.testing.expect(pre_missing.object.get("sha256").? == .null);
    const pre_exists = try preimageValue(allocator, true, 4, "abcd");
    try std.testing.expectEqualStrings("abcd", pre_exists.object.get("sha256").?.string);
    const identity = try identityFromText(allocator, "diagnostic text", "diag");
    try std.testing.expect(std.mem.startsWith(u8, identity.string, "diag:"));
}

/// Builds a test app fixture with the ports needed by this workflow.
fn diagnosticsTestApp(
    allocator: std.mem.Allocator,
    workspace_store: test_ports.WorkspaceStore,
    workspace_scanner: test_ports.WorkspaceScanner,
    command_runner: test_ports.CommandRunner,
    backend_probe: ?test_ports.BackendProbe,
    artifact_store: ?test_ports.ArtifactStore,
    platform: app_context.PlatformView,
) App {
    return App.init(.{
        .workspace = .{
            .root = "/repo",
            .cache_root = "/repo/.zigar-cache",
            .transport = "stdio",
        },
        .tool_paths = .{
            .zig = "/bin/zig",
            .zls = "/bin/zls",
            .zflame = "/bin/zflame",
            .diff_folded = "/bin/diff-folded",
        },
        .timeouts = .{
            .command_ms = 30_000,
            .zls_ms = 30_000,
        },
        .platform = platform,
        .command_runner = command_runner,
        .workspace_store = workspace_store,
        .workspace_scanner = workspace_scanner,
        .backend_probe = backend_probe,
        .artifact_store = artifact_store,
    }, allocator);
}

/// Parses test args input using caller-provided storage; malformed input and allocation failures propagate.
fn parseTestArgs(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, text, .{});
}

/// Implements expect kind workflow logic using caller-owned inputs.
fn expectKind(result: Result, expected: []const u8) !void {
    try expectStringField(result, "kind", expected);
}

/// Implements expect string field workflow logic using caller-owned inputs.
fn expectStringField(result: Result, field: []const u8, expected: []const u8) !void {
    try std.testing.expect(result.value == .object);
    try std.testing.expectEqualStrings(expected, result.value.object.get(field).?.string);
}

/// Implements expect nested string workflow logic using caller-owned inputs.
fn expectNestedString(result: Result, object_field: []const u8, field: []const u8, expected: []const u8) !void {
    try std.testing.expect(result.value == .object);
    try std.testing.expectEqualStrings(expected, result.value.object.get(object_field).?.object.get(field).?.string);
}

/// Implements expect backend error workflow logic using caller-owned inputs.
fn expectBackendError(result: Result, backend: []const u8, error_kind: []const u8) !void {
    try expectKind(result, "backend_error");
    try expectStringField(result, "backend", backend);
    try expectStringField(result, "error_kind", error_kind);
}

/// Implements unavailable probe workflow logic using caller-owned inputs.
fn unavailableProbe(backend: []const u8, argv: []const []const u8) test_ports.BackendProbeRequest {
    return .{
        .backend = backend,
        .argv = argv,
        .cwd = "/repo",
        .timeout_ms = 5000,
        .provenance = "arch110-workflow-backend-check",
    };
}

const RecordingWorkspaceStore = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList(FileRecord) = .empty,
    scan_entries: std.ArrayList([]u8) = .empty,
    write_records: std.ArrayList(WriteRecord) = .empty,

    const FileRecord = struct {
        path: []u8,
        bytes: []u8,
    };

    const WriteRecord = struct {
        path: []u8,
        bytes: []u8,
    };

    /// Initializes the fixture with caller-provided state.
    fn init(allocator: std.mem.Allocator) RecordingWorkspaceStore {
        return .{ .allocator = allocator };
    }

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    fn deinit(self: *RecordingWorkspaceStore) void {
        for (self.files.items) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.bytes);
        }
        self.files.deinit(self.allocator);
        for (self.scan_entries.items) |path| self.allocator.free(path);
        self.scan_entries.deinit(self.allocator);
        for (self.write_records.items) |record| {
            self.allocator.free(record.path);
            self.allocator.free(record.bytes);
        }
        self.write_records.deinit(self.allocator);
        self.* = undefined;
    }

    /// Returns the fixture port table used by this test context.
    fn port(self: *RecordingWorkspaceStore) test_ports.WorkspaceStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .resolve = resolve,
                .read = read,
                .write = write,
                .scan_directory = scanDirectory,
            },
        };
    }

    /// Implements put fixture workflow logic using caller-owned inputs.
    fn putFixture(self: *RecordingWorkspaceStore, path: []const u8, bytes: []const u8) !void {
        try self.files.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, path),
            .bytes = try self.allocator.dupe(u8, bytes),
        });
    }

    /// Implements put scan entries workflow logic using caller-owned inputs.
    fn putScanEntries(self: *RecordingWorkspaceStore, entries: []const []const u8) !void {
        for (entries) |entry| try self.scan_entries.append(self.allocator, try self.allocator.dupe(u8, entry));
    }

    /// Resolves resolve from caller-provided inputs; borrowed data remains caller-owned and failures are propagated.
    fn resolve(_: *anyopaque, allocator: std.mem.Allocator, request: test_ports.WorkspaceResolveRequest) test_ports.PortError!test_ports.WorkspaceResolveResult {
        const path = try std.fmt.allocPrint(allocator, "/repo/{s}", .{request.path});
        return .{ .path = path, .owns_path = true };
    }

    /// Reads read data from the provided context without taking ownership of inputs.
    fn read(ptr: *anyopaque, allocator: std.mem.Allocator, request: test_ports.WorkspaceReadRequest) test_ports.PortError!test_ports.WorkspaceReadResult {
        const self: *RecordingWorkspaceStore = @ptrCast(@alignCast(ptr));
        for (self.files.items) |file| {
            if (std.mem.eql(u8, file.path, request.path)) {
                const bytes = try allocator.dupe(u8, file.bytes);
                return .{ .bytes = bytes, .owns_bytes = true };
            }
        }
        return error.FileNotFound;
    }

    /// Writes write fields to the provided JSON stream and propagates writer failures.
    fn write(ptr: *anyopaque, request: test_ports.WorkspaceWriteRequest) test_ports.PortError!test_ports.WorkspaceWriteResult {
        const self: *RecordingWorkspaceStore = @ptrCast(@alignCast(ptr));
        try self.write_records.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, request.path),
            .bytes = try self.allocator.dupe(u8, request.bytes),
        });
        return .{ .bytes_written = request.bytes.len, .replaced_existing = true };
    }

    /// Scans fixture workspace entries and returns matching paths.
    fn scanDirectory(ptr: *anyopaque, allocator: std.mem.Allocator, request: test_ports.WorkspaceDirectoryScanRequest) test_ports.PortError!test_ports.WorkspaceDirectoryScanResult {
        _ = request;
        const self: *RecordingWorkspaceStore = @ptrCast(@alignCast(ptr));
        const entries = try allocator.alloc(test_ports.WorkspaceDirectoryEntry, self.scan_entries.items.len);
        for (self.scan_entries.items, 0..) |entry, index| entries[index] = .{ .path = try allocator.dupe(u8, entry) };
        return .{ .entries = entries, .owns_memory = true };
    }
};

const RecordingArtifactStore = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,

    const Record = struct {
        path: []u8,
        kind: []u8,
        bytes_len: usize,
    };

    /// Initializes the fixture with caller-provided state.
    fn init(allocator: std.mem.Allocator) RecordingArtifactStore {
        return .{ .allocator = allocator };
    }

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    fn deinit(self: *RecordingArtifactStore) void {
        for (self.records.items) |record| {
            self.allocator.free(record.path);
            self.allocator.free(record.kind);
        }
        self.records.deinit(self.allocator);
        self.* = undefined;
    }

    /// Returns the fixture port table used by this test context.
    fn port(self: *RecordingArtifactStore) test_ports.ArtifactStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .put = put,
                .read = read,
                .record_workspace = recordWorkspace,
            },
        };
    }

    /// Stores workspace fixture bytes for the requested path.
    fn put(_: *anyopaque, _: std.mem.Allocator, _: test_ports.ArtifactWriteRequest) test_ports.PortError!test_ports.ArtifactRef {
        return error.UnexpectedCall;
    }

    /// Reads read data from the provided context without taking ownership of inputs.
    fn read(_: *anyopaque, _: std.mem.Allocator, _: test_ports.ArtifactReadRequest) test_ports.PortError!test_ports.ArtifactReadResult {
        return error.UnexpectedCall;
    }

    /// Implements record workspace workflow logic using caller-owned inputs.
    fn recordWorkspace(ptr: *anyopaque, allocator: std.mem.Allocator, request: test_ports.WorkspaceArtifactRecordRequest) test_ports.PortError!test_ports.WorkspaceArtifactRef {
        const self: *RecordingArtifactStore = @ptrCast(@alignCast(ptr));
        try self.records.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, request.path),
            .kind = try self.allocator.dupe(u8, request.artifact_kind),
            .bytes_len = if (request.bytes) |bytes| bytes.len else 0,
        });
        return .{
            .path = try allocator.dupe(u8, request.path),
            .abs_path = try std.fmt.allocPrint(allocator, "/repo/{s}", .{request.path}),
            .bytes = if (request.bytes) |bytes| bytes.len else 0,
            .sha256 = try allocator.dupe(u8, "sha256:fake"),
            .indexed_at_unix_ms = request.indexed_at_unix_ms,
            .owns_memory = true,
        };
    }
};
