const std = @import("std");
const smoke = @import("../smoke_support.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const valueAt = smoke.valueAt;

pub fn run(allocator: std.mem.Allocator, io: Io, port: u16, expected: JsonValue, scenario_count: *usize) !void {
    try assertToolPaths(allocator, io, port, 70, "zigar_workspace_map", "{}", expected, "workspace_map_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 71, "zigar_roots_sync", "{\"roots\":\"file://src\\n\",\"apply\":false}", expected, "roots_sync_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 72, "zigar_resource_query", "{\"uri\":\"zigar://jobs\"}", expected, "resource_query_jobs_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 73, "zigar_prompt_pack", "{\"workflow\":\"zigar_test_workflow\"}", expected, "prompt_pack_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 74, "zigar_agent_guide_v2", "{\"client\":\"codex\",\"task\":\"test\"}", expected, "agent_guide_v2_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 75, "zigar_client_guide", "{\"client\":\"codex\"}", expected, "client_guide_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 76, "zigar_job_start", "{\"command\":\"check\",\"file\":\"src/main.zig\",\"timeout_ms\":10000}", expected, "job_start_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 77, "zigar_job_status", "{\"job_id\":\"job-1\"}", expected, "job_status_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 78, "zigar_job_result", "{\"job_id\":\"job-1\",\"limit\":5}", expected, "job_result_paths", scenario_count);
    try smoke.assertHttpRpcContains(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":95,\"method\":\"tasks/get\",\"params\":{\"taskId\":\"job-1\"}}", "\"taskId\":\"job-1\"", scenario_count);
    try smoke.assertHttpRpcContains(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":96,\"method\":\"tasks/result\",\"params\":{\"taskId\":\"job-1\"}}", "\"job_id\":\"job-1\"", scenario_count);
    try assertToolPaths(allocator, io, port, 79, "zigar_run_events", "{\"job_id\":\"job-1\",\"limit\":5}", expected, "run_events_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 80, "zigar_job_cancel", "{\"job_id\":\"job-1\",\"reason\":\"fixture\"}", expected, "job_cancel_paths", scenario_count);
    try smoke.assertHttpRpcContains(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":97,\"method\":\"tasks/cancel\",\"params\":{\"taskId\":\"job-1\"}}", "\"taskId\":\"job-1\"", scenario_count);
    try assertToolPaths(allocator, io, port, 81, "zigar_cancel_status", "{\"job_id\":\"job-1\"}", expected, "cancel_status_paths", scenario_count);
    try smoke.assertHttpRpcContains(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":90,\"method\":\"resources/read\",\"params\":{\"uri\":\"zigar://workspace/roots\"}}", "zigar_workspace_roots_resource", scenario_count);
    try smoke.assertHttpRpcContains(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":91,\"method\":\"resources/read\",\"params\":{\"uri\":\"zigar://file/src/main.zig/imports\"}}", "zigar_dynamic_file_resource", scenario_count);
    try smoke.assertHttpRpcContains(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":98,\"method\":\"resources/templates/list\"}", "zigar://artifacts/{sha}", scenario_count);
    try smoke.assertHttpRpcContains(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":92,\"method\":\"prompts/get\",\"params\":{\"name\":\"zigar_compile_error_workflow\",\"arguments\":{}}}", "zig_compile_error_index", scenario_count);
    try smoke.assertHttpRpcContains(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":93,\"method\":\"completion/complete\",\"params\":{\"argument\":{\"name\":\"command\",\"value\":\"b\"}}}", "build-test", scenario_count);
    try smoke.assertHttpRpcContains(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"completion/complete\",\"params\":{\"argument\":{\"name\":\"uri\",\"value\":\"zigar://art\"}}}", "zigar://artifacts/{sha}", scenario_count);
    try smoke.assertHttpRpcContains(allocator, io, port, "{\"jsonrpc\":\"2.0\",\"id\":94,\"method\":\"tasks/list\",\"params\":{\"limit\":5}}", "job-1", scenario_count);
}

fn assertToolPaths(allocator: std.mem.Allocator, io: Io, port: u16, id: i64, tool_name: []const u8, args_json: []const u8, expected_root: JsonValue, expected_key: []const u8, scenario_count: *usize) !void {
    const tool_json = try smoke.callHttpToolJson(allocator, io, port, id, tool_name, args_json);
    defer allocator.free(tool_json);
    const parsed = try std.json.parseFromSlice(JsonValue, allocator, tool_json, .{});
    defer parsed.deinit();
    var it = expected_root.object.get(expected_key).?.object.iterator();
    while (it.next()) |entry| {
        const actual = valueAt(parsed.value, entry.key_ptr.*) orelse return error.AssertionFailed;
        try smoke.expectJsonEq(io, actual, entry.value_ptr.*, entry.key_ptr.*);
    }
    scenario_count.* += 1;
}

test "http runtime UX smoke exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
