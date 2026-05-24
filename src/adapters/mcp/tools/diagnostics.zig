const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const workflows = @import("../../../app/usecases/diagnostics/workflows.zig");
const mcp_errors = @import("../errors.zig");
const mcp_result = @import("../result.zig");

pub fn zigDebugPlan(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_debug_plan", workflows.zigDebugPlan);
}

pub fn zigLldbBacktrace(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_lldb_backtrace", workflows.zigLldbBacktrace);
}

pub fn zigCoreInspect(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_core_inspect", workflows.zigCoreInspect);
}

pub fn zigDebugFrameSummary(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_debug_frame_summary", workflows.zigDebugFrameSummary);
}

pub fn zigSanitizerFusion(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_sanitizer_fusion", workflows.zigSanitizerFusion);
}

pub fn zigPanicTraceAnalyze(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_panic_trace_analyze", workflows.zigPanicTraceAnalyze);
}

pub fn zigCrashReproPlan(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_crash_repro_plan", workflows.zigCrashReproPlan);
}

pub fn zigHeaptrackRun(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_heaptrack_run", workflows.zigHeaptrackRun);
}

pub fn zigHeaptrackSummary(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_heaptrack_summary", workflows.zigHeaptrackSummary);
}

pub fn zigValgrindMemcheck(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_valgrind_memcheck", workflows.zigValgrindMemcheck);
}

pub fn zigCallgrindReport(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_callgrind_report", workflows.zigCallgrindReport);
}

pub fn zigFuzzPlan(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_fuzz_plan", workflows.zigFuzzPlan);
}

pub fn zigAflRun(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_afl_run", workflows.zigAflRun);
}

pub fn zigLibfuzzerRun(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_libfuzzer_run", workflows.zigLibfuzzerRun);
}

pub fn zigFuzzCrashMinimize(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_fuzz_crash_minimize", workflows.zigFuzzCrashMinimize);
}

pub fn zigFuzzCorpusSummary(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_fuzz_corpus_summary", workflows.zigFuzzCorpusSummary);
}

pub fn zigBinarySize(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_binary_size", workflows.zigBinarySize);
}

pub fn zigBinarySizeDiff(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_binary_size_diff", workflows.zigBinarySizeDiff);
}

pub fn zigObjdumpSummary(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_objdump_summary", workflows.zigObjdumpSummary);
}

pub fn zigDwarfdumpCheck(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_dwarfdump_check", workflows.zigDwarfdumpCheck);
}

pub fn zigSymbolize(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_symbolize", workflows.zigSymbolize);
}

pub fn zigQemuTest(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_qemu_test", workflows.zigQemuTest);
}

pub fn zigCrossSmoke(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_cross_smoke", workflows.zigCrossSmoke);
}

pub fn zigTargetRuntimePlan(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_target_runtime_plan", workflows.zigTargetRuntimePlan);
}

pub fn zigEmbeddedDetect(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_embedded_detect", workflows.zigEmbeddedDetect);
}

pub fn zigMicrozigPlan(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_microzig_plan", workflows.zigMicrozigPlan);
}

pub fn zigBoardProfile(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_board_profile", workflows.zigBoardProfile);
}

pub fn zigFlashPlan(allocator: std.mem.Allocator, context: app_context.DiagnosticsContext, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invoke(allocator, context, args, "zig_flash_plan", workflows.zigFlashPlan);
}

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
