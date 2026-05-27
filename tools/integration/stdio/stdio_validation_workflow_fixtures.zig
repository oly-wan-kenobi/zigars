pub fn run(client: anytype) !void {
    const semantic_impact = try client.callTool("zig_impact_semantic", "{\"files\":\"src/main.zig\",\"symbols\":\"main\",\"limit\":10}");
    defer client.allocator.free(semantic_impact);
    try client.expectPathString(semantic_impact, "kind", "zig_impact_semantic");
    try client.expectPathString(semantic_impact, "capability_tier", "parser_backed");

    const semantic_select = try client.callTool("zig_test_select_semantic", "{\"files\":\"src/main.zig\",\"symbols\":\"main\",\"limit\":10}");
    defer client.allocator.free(semantic_select);
    try client.expectPathString(semantic_select, "kind", "zig_test_select_semantic");
    try client.expectPathString(semantic_select, "selection_basis", "parser-backed semantic impact plus conservative fallback");

    const validation_plan = try client.callTool("zigars_validation_plan", "{\"mode\":\"quick\",\"changed_files\":\"notes.txt\"}");
    defer client.allocator.free(validation_plan);
    try client.expectPathString(validation_plan, "kind", "zigars_validation_plan");
    try client.expectPathString(validation_plan, "mode", "quick");

    const validation_run = try client.callTool("zigars_validation_run", "{\"mode\":\"quick\",\"changed_files\":\"notes.txt\",\"apply\":false}");
    defer client.allocator.free(validation_run);
    try client.expectPathString(validation_run, "kind", "zigars_validation_run");
    try client.expectPathJson(validation_run, "history_applied", .{ .bool = false });

    const build_events = try client.callTool("zig_build_events", "{\"text\":\"src/main.zig:1:1: error: fixture failure\\n\"}");
    defer client.allocator.free(build_events);
    try client.expectPathString(build_events, "kind", "zig_build_events");
    try client.expectPathJson(build_events, "summary.compiler_error_count", .{ .integer = 1 });

    const test_events = try client.callTool("zig_test_events", "{\"text\":\"1/1 test.foo...FAIL (TestExpectedEqual) 12ms\\n\"}");
    defer client.allocator.free(test_events);
    try client.expectPathString(test_events, "kind", "zig_test_events");
    try client.expectPathJson(test_events, "summary.test_failure_count", .{ .integer = 1 });

    const test_timing = try client.callTool("zig_test_timing", "{\"text\":\"1/1 test.foo...PASS 12ms\\n\"}");
    defer client.allocator.free(test_timing);
    try client.expectPathString(test_timing, "kind", "zig_test_timing");
    try client.expectPathJson(test_timing, "timings.0.duration_ms", .{ .integer = 12 });

    const validation_history = try client.callTool("zigars_validation_history", "{}");
    defer client.allocator.free(validation_history);
    try client.expectPathString(validation_history, "kind", "zigars_validation_history");
    try client.expectPathJson(validation_history, "run_count", .{ .integer = 0 });

    const flake_history = try client.callTool("zig_test_flake_history", "{}");
    defer client.allocator.free(flake_history);
    try client.expectPathString(flake_history, "kind", "zig_test_flake_history");

    const failure_history = try client.callTool("zig_failure_history", "{}");
    defer client.allocator.free(failure_history);
    try client.expectPathString(failure_history, "kind", "zig_failure_history");

    const session_snapshot = try client.callTool("zigars_session_snapshot", "{\"goal\":\"handoff validation\",\"changed_files\":\"src/main.zig\"}");
    defer client.allocator.free(session_snapshot);
    try client.expectPathString(session_snapshot, "kind", "zigars_session_snapshot");
    try client.expectPathString(session_snapshot, "goal", "handoff validation");

    const handoff_pack = try client.callTool("zigars_handoff_pack", "{\"goal\":\"handoff validation\",\"changed_files\":\"src/main.zig\"}");
    defer client.allocator.free(handoff_pack);
    try client.expectPathString(handoff_pack, "kind", "zigars_handoff_pack");
    try client.expectPathJson(handoff_pack, "portable", .{ .bool = true });

    const decision = try client.callTool("zigars_decision_record", "{\"title\":\"Use apply gates\",\"decision\":\"Writes require apply=true\",\"apply\":false}");
    defer client.allocator.free(decision);
    try client.expectPathString(decision, "kind", "zigars_decision_record");
    try client.expectPathJson(decision, "applied", .{ .bool = false });

    const notes = try client.callTool("zigars_project_notes", "{\"content\":\"{\\\"category\\\":\\\"architecture\\\",\\\"title\\\":\\\"Apply gates\\\",\\\"decision\\\":\\\"Writes need apply=true\\\"}\\n\",\"query\":\"apply\"}");
    defer client.allocator.free(notes);
    try client.expectPathString(notes, "kind", "zigars_project_notes");
    try client.expectPathJson(notes, "note_count", .{ .integer = 1 });

    const memory = try client.callTool("zigars_project_memory", "{\"content\":\"{\\\"category\\\":\\\"architecture\\\",\\\"title\\\":\\\"Apply gates\\\",\\\"decision\\\":\\\"Writes need apply=true\\\"}\\n\",\"query\":\"apply\"}");
    defer client.allocator.free(memory);
    try client.expectPathString(memory, "kind", "zigars_project_memory");
    try client.expectPathJson(memory, "note_count", .{ .integer = 1 });

    const capability_match = try client.callTool("zigars_capability_match", "{\"goal\":\"plan validation for changed tests\",\"limit\":3}");
    defer client.allocator.free(capability_match);
    try client.expectPathString(capability_match, "kind", "zigars_capability_match");

    const sequence_plan = try client.callTool("zigars_tool_sequence_plan", "{\"goal\":\"fix failing tests\",\"changed_files\":\"src/main.zig\"}");
    defer client.allocator.free(sequence_plan);
    try client.expectPathString(sequence_plan, "kind", "zigars_tool_sequence_plan");
}

test "stdio validation workflow fixture exposes run entrypoint" {
    try @import("std").testing.expect(@hasDecl(@This(), "run"));
}
