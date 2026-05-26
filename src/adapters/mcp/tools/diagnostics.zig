//! Diagnostics and crash-analysis MCP adapters over app-layer diagnostic workflows.
const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const workflows = @import("../../../app/usecases/diagnostics/workflows.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

/// Handles MCP `zig_debug_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDebugPlan(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_debug_plan", workflows.zigDebugPlan);
}

/// Handles MCP `zig_lldb_backtrace` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLldbBacktrace(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_lldb_backtrace", workflows.zigLldbBacktrace);
}

/// Handles MCP `zig_core_inspect` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCoreInspect(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_core_inspect", workflows.zigCoreInspect);
}

/// Handles MCP `zig_debug_frame_summary` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDebugFrameSummary(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_debug_frame_summary", workflows.zigDebugFrameSummary);
}

/// Handles MCP `zig_sanitizer_fusion` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSanitizerFusion(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_sanitizer_fusion", workflows.zigSanitizerFusion);
}

/// Handles MCP `zig_panic_trace_analyze` requests by delegating to app logic and shaping owned results/errors.
pub fn zigPanicTraceAnalyze(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_panic_trace_analyze", workflows.zigPanicTraceAnalyze);
}

/// Handles MCP `zig_crash_repro_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCrashReproPlan(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_crash_repro_plan", workflows.zigCrashReproPlan);
}

/// Handles MCP `zig_heaptrack_run` requests by delegating to app logic and shaping owned results/errors.
pub fn zigHeaptrackRun(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_heaptrack_run", workflows.zigHeaptrackRun);
}

/// Handles MCP `zig_heaptrack_summary` requests by delegating to app logic and shaping owned results/errors.
pub fn zigHeaptrackSummary(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_heaptrack_summary", workflows.zigHeaptrackSummary);
}

/// Handles MCP `zig_valgrind_memcheck` requests by delegating to app logic and shaping owned results/errors.
pub fn zigValgrindMemcheck(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_valgrind_memcheck", workflows.zigValgrindMemcheck);
}

/// Handles MCP `zig_callgrind_report` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCallgrindReport(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_callgrind_report", workflows.zigCallgrindReport);
}

/// Handles MCP `zig_fuzz_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigFuzzPlan(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_fuzz_plan", workflows.zigFuzzPlan);
}

/// Handles MCP `zig_afl_run` requests by delegating to app logic and shaping owned results/errors.
pub fn zigAflRun(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_afl_run", workflows.zigAflRun);
}

/// Handles MCP `zig_libfuzzer_run` requests by delegating to app logic and shaping owned results/errors.
pub fn zigLibfuzzerRun(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_libfuzzer_run", workflows.zigLibfuzzerRun);
}

/// Handles MCP `zig_fuzz_crash_minimize` requests by delegating to app logic and shaping owned results/errors.
pub fn zigFuzzCrashMinimize(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_fuzz_crash_minimize", workflows.zigFuzzCrashMinimize);
}

/// Handles MCP `zig_fuzz_corpus_summary` requests by delegating to app logic and shaping owned results/errors.
pub fn zigFuzzCorpusSummary(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_fuzz_corpus_summary", workflows.zigFuzzCorpusSummary);
}

/// Handles MCP `zig_binary_size` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBinarySize(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_binary_size", workflows.zigBinarySize);
}

/// Handles MCP `zig_binary_size_diff` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBinarySizeDiff(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_binary_size_diff", workflows.zigBinarySizeDiff);
}

/// Handles MCP `zig_objdump_summary` requests by delegating to app logic and shaping owned results/errors.
pub fn zigObjdumpSummary(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_objdump_summary", workflows.zigObjdumpSummary);
}

/// Handles MCP `zig_dwarfdump_check` requests by delegating to app logic and shaping owned results/errors.
pub fn zigDwarfdumpCheck(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dwarfdump_check", workflows.zigDwarfdumpCheck);
}

/// Handles MCP `zig_symbolize` requests by delegating to app logic and shaping owned results/errors.
pub fn zigSymbolize(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_symbolize", workflows.zigSymbolize);
}

/// Handles MCP `zig_qemu_test` requests by delegating to app logic and shaping owned results/errors.
pub fn zigQemuTest(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_qemu_test", workflows.zigQemuTest);
}

/// Handles MCP `zig_cross_smoke` requests by delegating to app logic and shaping owned results/errors.
pub fn zigCrossSmoke(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_cross_smoke", workflows.zigCrossSmoke);
}

/// Handles MCP `zig_target_runtime_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigTargetRuntimePlan(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_target_runtime_plan", workflows.zigTargetRuntimePlan);
}

/// Handles MCP `zig_embedded_detect` requests by delegating to app logic and shaping owned results/errors.
pub fn zigEmbeddedDetect(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_embedded_detect", workflows.zigEmbeddedDetect);
}

/// Handles MCP `zig_microzig_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigMicrozigPlan(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_microzig_plan", workflows.zigMicrozigPlan);
}

/// Handles MCP `zig_board_profile` requests by delegating to app logic and shaping owned results/errors.
pub fn zigBoardProfile(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_board_profile", workflows.zigBoardProfile);
}

/// Handles MCP `zig_flash_plan` requests by delegating to app logic and shaping owned results/errors.
pub fn zigFlashPlan(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_flash_plan", workflows.zigFlashPlan);
}

/// Invokes a use case and converts its result or failure into MCP output.
fn invoke(
    allocator: std.mem.Allocator,
    context: app_context.DiagnosticsContext,
    args: ?std.json.Value,
    comptime tool_name: []const u8,
    comptime func: anytype,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var app = workflows.App.init(context, allocator);
    const result = func(&app, allocator, args) catch |err| return usecaseError(allocator, tool_name, err);
    if (result.is_error) {
        defer mcp_result.deinitOwnedValue(allocator, result.value);
        return mcp_result.structuredError(allocator, result.value);
    }
    return mcp_result.structuredOwned(allocator, result.value);
}

/// Maps usecase error failures to structured MCP errors.
fn usecaseError(allocator: std.mem.Allocator, tool_name: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_errors.fromError(allocator, .{
        .tool = tool_name,
        .operation = "diagnostics_workflow",
        .phase = "run_usecase",
        .code = "diagnostics_usecase_failed",
        .category = "diagnostics",
        .resolution = "Retry after confirming the supplied evidence, workspace paths, and optional backend paths.",
    }, err);
}

const fakes = @import("../../../testing/fakes/root.zig");

test "diagnostics adapter maps structured and thrown usecase failures" {
    const Stub = struct {
        /// Test stub that returns a structured tool failure.
        fn structuredFailure(_: *workflows.App, allocator: std.mem.Allocator, _: ?std.json.Value) !workflows.Result {
            var obj = std.json.ObjectMap.empty;
            const key = try allocator.dupe(u8, "kind");
            var key_owned = true;
            defer if (key_owned) allocator.free(key);
            const value = try allocator.dupe(u8, "diagnostics_failure");
            var value_owned = true;
            defer if (value_owned) allocator.free(value);
            try obj.put(allocator, key, .{ .string = value });
            key_owned = false;
            value_owned = false;
            return .{ .value = .{ .object = obj }, .is_error = true };
        }

        /// Test stub that throws a tool failure error.
        fn thrownFailure(_: *workflows.App, _: std.mem.Allocator, _: ?std.json.Value) !workflows.Result {
            return error.AccessDenied;
        }

        /// Test stub that simulates allocation failure.
        fn oomFailure(_: *workflows.App, _: std.mem.Allocator, _: ?std.json.Value) !workflows.Result {
            return error.OutOfMemory;
        }
    };

    var runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer runner.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    const context: app_context.DiagnosticsContext = .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .tool_paths = .{},
        .timeouts = .{},
        .command_runner = runner.port(),
        .workspace_store = workspace.port(),
        .workspace_scanner = scanner.port(),
    };

    const structured = try invoke(std.testing.allocator, context, null, "zig_debug_plan", Stub.structuredFailure);
    defer mcp_result.deinitToolResult(std.testing.allocator, structured);
    try std.testing.expect(structured.is_error);
    try std.testing.expectEqualStrings("diagnostics_failure", structured.structuredContent.?.object.get("kind").?.string);

    const thrown = try invoke(std.testing.allocator, context, null, "zig_debug_plan", Stub.thrownFailure);
    defer mcp_result.deinitToolResult(std.testing.allocator, thrown);
    try std.testing.expect(thrown.is_error);
    try std.testing.expectEqualStrings("tool_error", thrown.structuredContent.?.object.get("kind").?.string);

    try std.testing.expectError(error.OutOfMemory, invoke(std.testing.allocator, context, null, "zig_debug_plan", Stub.oomFailure));
}
