const std = @import("std");
const smoke = @import("smoke_support.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const valueAt = smoke.valueAt;

pub fn run(allocator: std.mem.Allocator, io: Io, port: u16, expected: JsonValue, scenario_count: *usize) !void {
    try assertToolPaths(allocator, io, port, 101, "zig_impact_semantic", "{\"files\":\"src/main.zig\",\"symbols\":\"main\",\"limit\":20}", expected, "semantic_impact_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 102, "zig_test_select_semantic", "{\"files\":\"src/main.zig\",\"symbols\":\"main\",\"limit\":20}", expected, "semantic_test_select_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 103, "zigar_validation_plan", "{\"mode\":\"quick\",\"changed_files\":\"notes.txt\"}", expected, "validation_plan_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 104, "zigar_validation_run", "{\"mode\":\"quick\",\"changed_files\":\"notes.txt\",\"apply\":false}", expected, "validation_run_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 105, "zig_build_events", "{\"text\":\"src/main.zig:1:1: error: fixture failure\\n\"}", expected, "build_events_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 106, "zig_test_events", "{\"text\":\"1/1 test.foo...FAIL (TestExpectedEqual) 12ms\\n\"}", expected, "test_events_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 107, "zig_test_timing", "{\"text\":\"1/1 test.foo...PASS 12ms\\n\"}", expected, "test_timing_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 108, "zigar_validation_history", "{}", expected, "validation_history_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 109, "zig_test_flake_history", "{}", expected, "flake_history_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 110, "zig_failure_history", "{}", expected, "failure_history_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 111, "zigar_session_snapshot", "{\"goal\":\"handoff validation\",\"changed_files\":\"src/main.zig\"}", expected, "session_snapshot_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 112, "zigar_handoff_pack", "{\"goal\":\"handoff validation\",\"changed_files\":\"src/main.zig\"}", expected, "handoff_pack_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 113, "zigar_decision_record", "{\"title\":\"Use apply gates\",\"decision\":\"Writes require apply=true\",\"apply\":false}", expected, "decision_record_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 114, "zigar_project_notes", "{\"content\":\"{\\\"category\\\":\\\"architecture\\\",\\\"title\\\":\\\"Apply gates\\\",\\\"decision\\\":\\\"Writes need apply=true\\\"}\\n\",\"query\":\"apply\"}", expected, "project_notes_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 115, "zigar_project_memory", "{\"content\":\"{\\\"category\\\":\\\"architecture\\\",\\\"title\\\":\\\"Apply gates\\\",\\\"decision\\\":\\\"Writes need apply=true\\\"}\\n\",\"query\":\"apply\"}", expected, "project_memory_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 116, "zigar_capability_match", "{\"goal\":\"plan validation for changed tests\",\"limit\":3}", expected, "capability_match_paths", scenario_count);
    try assertToolPaths(allocator, io, port, 117, "zigar_tool_sequence_plan", "{\"goal\":\"fix failing tests\",\"changed_files\":\"src/main.zig\"}", expected, "tool_sequence_plan_paths", scenario_count);
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

test "http validation workflow smoke exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
