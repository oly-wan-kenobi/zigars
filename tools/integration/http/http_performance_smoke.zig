//! HTTP smoke fixture for the performance tool family: coverage, bench,
//! performance-budget, profiling, and tracy tools (IDs 170-193). Each scenario
//! asserts the structured-result JSON paths returned by the live HTTP server
//! against expectations stored in the shared fixture JSON.

const std = @import("std");
const builtin = @import("builtin");
const cli_io = @import("../../common/cli_io.zig");
const smoke = @import("../smoke_support.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const stderrPrint = cli_io.stderrPrint;
const valueAt = smoke.valueAt;

/// Exercises performance tools through the HTTP transport and asserts structured
/// result paths against `expected`. Clears the bench-regression-gate session
/// file before the gate tool call to ensure the assertion starts from a known
/// state. `scenarios` is incremented once per successful assertion group.
pub fn run(allocator: std.mem.Allocator, io: Io, port: u16, expected: JsonValue, scenarios: *usize) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const coverage = "SF:src/main.zig\\nDA:1,1\\nDA:2,0\\nend_of_record\\n";
    const full_coverage = "SF:src/main.zig\\nDA:1,1\\nend_of_record\\n";
    const profile = "{\\\"threads\\\":[{\\\"name\\\":\\\"main\\\",\\\"samples\\\":{\\\"data\\\":[[0],[1]]},\\\"frameTable\\\":{\\\"length\\\":1}}]}";
    const comparison = "{\\\"regressions\\\":[{\\\"name\\\":\\\"parse\\\",\\\"delta_pct\\\":20}],\\\"worst_regression_pct\\\":20}";
    const coverage_map_args = try std.fmt.allocPrint(allocator, "{{\"mode\":\"map\",\"content\":\"{s}\"}}", .{coverage});
    defer allocator.free(coverage_map_args);
    const coverage_merge_args = try std.fmt.allocPrint(allocator, "{{\"left\":\"{s}\",\"right\":\"{s}\",\"apply\":false}}", .{ coverage, full_coverage });
    defer allocator.free(coverage_merge_args);
    const coverage_diff_args = try std.fmt.allocPrint(allocator, "{{\"mode\":\"diff\",\"current\":\"{s}\",\"baseline\":\"{s}\"}}", .{ coverage, full_coverage });
    defer allocator.free(coverage_diff_args);
    const coverage_baseline_args = try std.fmt.allocPrint(allocator, "{{\"content\":\"{s}\",\"apply\":false}}", .{coverage});
    defer allocator.free(coverage_baseline_args);
    const coverage_budget_args = try std.fmt.allocPrint(allocator, "{{\"mode\":\"budget\",\"coverage\":\"{s}\",\"min_line_rate_bp\":4000}}", .{coverage});
    defer allocator.free(coverage_budget_args);
    const perf_budget_args = try std.fmt.allocPrint(allocator, "{{\"comparison\":\"{s}\",\"max_regression_pct\":5}}", .{comparison});
    defer allocator.free(perf_budget_args);
    const profile_regression_args = try std.fmt.allocPrint(allocator, "{{\"comparison\":\"{s}\",\"backend\":\"samply\"}}", .{comparison});
    defer allocator.free(profile_regression_args);
    const samply_summary_args = try std.fmt.allocPrint(allocator, "{{\"content\":\"{s}\"}}", .{profile});
    defer allocator.free(samply_summary_args);
    const samply_import_args = try std.fmt.allocPrint(allocator, "{{\"content\":\"{s}\",\"apply\":false}}", .{profile});
    defer allocator.free(samply_import_args);

    try assertToolPaths(allocator, io, port, 170, "zig_coverage_run", "{\"command\":\"zig build test\",\"apply\":false}", expected, "coverage_run_paths", scenarios);
    try assertToolPaths(allocator, io, port, 171, "zig_coverage", coverage_map_args, expected, "coverage_map_paths", scenarios);
    try assertToolPaths(allocator, io, port, 172, "zig_coverage_merge", coverage_merge_args, expected, "coverage_merge_paths", scenarios);
    try assertToolPaths(allocator, io, port, 173, "zig_coverage", coverage_diff_args, expected, "coverage_diff_paths", scenarios);
    try assertToolPaths(allocator, io, port, 174, "zig_coverage_baseline", coverage_baseline_args, expected, "coverage_baseline_paths", scenarios);
    try assertToolPaths(allocator, io, port, 175, "zig_coverage", coverage_budget_args, expected, "coverage_budget_paths", scenarios);
    try assertToolPaths(allocator, io, port, 176, "zig_bench_discover", "{\"limit\":5}", expected, "bench_discover_paths", scenarios);
    try assertToolPaths(allocator, io, port, 177, "zig_bench_run", "{\"command\":\"zig build bench\",\"apply\":false}", expected, "bench_run_paths", scenarios);
    try assertToolPaths(allocator, io, port, 178, "zig_bench_baseline", "{\"results\":\"parse: 100 ns\\n\",\"apply\":false}", expected, "bench_baseline_paths", scenarios);
    try assertToolPaths(allocator, io, port, 179, "zig_benchmark_history", "{}", expected, "benchmark_history_paths", scenarios);
    try assertToolPaths(allocator, io, port, 180, "zig_bench_compare", "{\"current\":\"parse: 120 ns\\n\",\"baseline\":\"parse: 100 ns\\n\",\"threshold_pct\":5}", expected, "bench_compare_paths", scenarios);
    try removeFixtureSession(io, "smoke-gate");
    try assertToolPaths(allocator, io, port, 181, "zig_bench_regression_gate", "{\"current\":\"parse: 120 ns\\n\",\"baseline\":\"parse: 100 ns\\n\",\"threshold_pct\":5,\"session_id\":\"smoke-gate\",\"apply\":true}", expected, "bench_regression_gate_paths", scenarios);
    try assertToolPaths(allocator, io, port, 194, "zigars_session_view", "{\"kind\":\"bench_regression_gate\",\"id\":\"smoke-gate\"}", expected, "session_view_paths", scenarios);
    try assertToolPaths(allocator, io, port, 182, "zig_perf_budget_check", perf_budget_args, expected, "perf_budget_paths", scenarios);
    try assertToolPaths(allocator, io, port, 183, "zig_profile_regression", profile_regression_args, expected, "profile_regression_paths", scenarios);
    // Samply recording is intentionally unsupported on Windows; expect the
    // structured unsupported-platform result there instead of a record plan.
    const samply_record_key = if (builtin.os.tag == .windows) "samply_record_paths_windows" else "samply_record_paths";
    try assertToolPaths(allocator, io, port, 184, "zig_samply_record", "{\"command\":\"zig build test\",\"apply\":false}", expected, samply_record_key, scenarios);
    try assertToolPaths(allocator, io, port, 185, "zig_samply_summary", samply_summary_args, expected, "samply_summary_paths", scenarios);
    try assertToolPaths(allocator, io, port, 186, "zig_samply_import", samply_import_args, expected, "samply_import_paths", scenarios);
    try assertToolPaths(allocator, io, port, 187, "zig_samply_artifact", "{\"path\":\"tests/fixtures/http-smoke.expect.json\",\"apply\":false}", expected, "samply_artifact_paths", scenarios);
    try assertToolPaths(allocator, io, port, 187, "zig_profile_open", "{\"path\":\"tests/fixtures/http-smoke.expect.json\"}", expected, "profile_open_paths", scenarios);
    try assertToolPaths(allocator, io, port, 188, "zig_tracy_plan", "{\"limit\":5}", expected, "tracy_plan_paths", scenarios);
    try assertToolPaths(allocator, io, port, 189, "zig_tracy_probe", "{\"probe_backend\":false}", expected, "tracy_probe_paths", scenarios);
    // Tracy capture is intentionally unsupported on Windows; see samply above.
    const tracy_capture_key = if (builtin.os.tag == .windows) "tracy_capture_paths_windows" else "tracy_capture_paths";
    try assertToolPaths(allocator, io, port, 190, "zig_tracy_capture", "{\"apply\":false}", expected, tracy_capture_key, scenarios);
    try assertToolPaths(allocator, io, port, 191, "zig_tracy_artifacts", "{\"path\":\"tests/fixtures/http-smoke.expect.json\",\"apply\":false}", expected, "tracy_artifacts_paths", scenarios);
    try assertToolPaths(allocator, io, port, 192, "zig_tracy_hints", "{}", expected, "tracy_hints_paths", scenarios);
    try assertToolPaths(allocator, io, port, 193, "zig_perf_evidence_pack", "{\"coverage\":\"inline\",\"benchmarks\":\"inline\",\"apply\":false}", expected, "perf_evidence_pack_paths", scenarios);
}

/// Removes the bench-regression-gate session file for `session_id` so the gate
/// tool starts from an empty history. `FileNotFound` is silently accepted;
/// other errors propagate because they indicate a permission or path problem.
fn removeFixtureSession(io: Io, session_id: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zigars-cache/sessions/bench_regression_gate/{s}.jsonl", .{session_id});
    Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Invokes `tool_name` via HTTP JSON-RPC and asserts every JSON path in the
/// `expected_key` sub-object of `expected_root`. Logs the missing path to stderr
/// before returning `error.AssertionFailed`. Increments `scenario_count` on
/// success.
fn assertToolPaths(
    allocator: std.mem.Allocator,
    io: Io,
    port: u16,
    id: i64,
    tool_name: []const u8,
    args_json_owned_or_static: []const u8,
    expected_root: JsonValue,
    expected_key: []const u8,
    scenario_count: *usize,
) !void {
    // Normalize and constrain path handling here before any downstream filesystem action.
    const tool_json = try smoke.callHttpToolJson(allocator, io, port, id, tool_name, args_json_owned_or_static);
    defer allocator.free(tool_json);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, tool_json, .{});
    defer parsed.deinit();
    const expected_paths = expected_root.object.get(expected_key).?.object;
    var it = expected_paths.iterator();
    while (it.next()) |entry| {
        const actual = valueAt(parsed.value, entry.key_ptr.*) orelse {
            try stderrPrint(io, "{s}: missing path {s}\n", .{ tool_name, entry.key_ptr.* });
            return error.AssertionFailed;
        };
        try smoke.expectJsonEq(io, actual, entry.value_ptr.*, entry.key_ptr.*);
    }
    scenario_count.* += 1;
}

test "http performance smoke exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
