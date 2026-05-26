const std = @import("std");
const cli_io = @import("../../common/cli_io.zig");
const smoke = @import("../smoke_support.zig");

const Io = std.Io;
const JsonValue = std.json.Value;
const stderrPrint = cli_io.stderrPrint;
const valueAt = smoke.valueAt;

// Groups HTTP tool-result path assertions by ownership area. The expected
// values stay in JSON fixtures; this module only preserves call order and IDs.

/// Exercises static-analysis and index tools through the HTTP transport.
pub fn runStaticAnalysisAssertions(
    allocator: std.mem.Allocator,
    io: Io,
    port: u16,
    expected: JsonValue,
    scenarios: *usize,
) !void {
    try assertToolPaths(allocator, io, port, 5, "zig_check", "{\"file\":42}", expected, "argument_error_paths", scenarios);
    try assertToolPaths(allocator, io, port, 26, "zig_format", "{\"file\":\"missing.zig\"}", expected, "format_missing_file_paths", scenarios);
    try assertToolPaths(allocator, io, port, 6, "zig_compile_error_index", "{\"text\":\"src/main.zig:1:2: error: fixture failure\\nsrc/main.zig:1:2: note: fixture note\\n\"}", expected, "compile_error_index_paths", scenarios);
    try assertToolPaths(allocator, io, port, 7, "zig_target_matrix_plan", "{\"targets\":\"native wasm32-freestanding\",\"steps\":\"build\"}", expected, "target_matrix_paths", scenarios);
    try assertToolPaths(allocator, io, port, 8, "zig_toolchain_resolve", "{\"probe_managers\":false}", expected, "toolchain_paths", scenarios);
    try assertToolPaths(allocator, io, port, 9, "zig_dependency_inspect", "{}", expected, "dependency_paths", scenarios);
    try assertToolPaths(allocator, io, port, 10, "zig_build_options", "{}", expected, "build_options_paths", scenarios);
    try assertToolPaths(allocator, io, port, 11, "zig_changed_files_plan", "{}", expected, "changed_files_plan_paths", scenarios);
    try assertToolPaths(allocator, io, port, 12, "zig_test_failure_triage", "{\"text\":\"1/1 test.foo...FAIL (TestExpectedEqual)\\nexpected 1, found 2\\n\"}", expected, "test_failure_triage_paths", scenarios);
    try assertToolPaths(allocator, io, port, 13, "zig_workspace_symbol_cache", "{\"query\":\"main\",\"limit\":20}", expected, "workspace_symbol_cache_paths", scenarios);
    try assertToolPaths(allocator, io, port, 80, "zig_semantic_index_build", "{\"limit\":20}", expected, "semantic_index_paths", scenarios);
    try assertToolPaths(allocator, io, port, 81, "zig_semantic_index_status", "{}", expected, "semantic_index_status_paths", scenarios);
    try assertToolPaths(allocator, io, port, 82, "zig_semantic_index_refresh", "{\"limit\":20}", expected, "semantic_index_refresh_paths", scenarios);
    try assertToolPaths(allocator, io, port, 83, "zig_semantic_query", "{\"query\":\"main\",\"limit\":5}", expected, "semantic_query_paths", scenarios);
    try assertToolPaths(allocator, io, port, 84, "zig_semantic_refs", "{\"symbol\":\"main\",\"limit\":5}", expected, "semantic_refs_paths", scenarios);
    try assertToolPaths(allocator, io, port, 85, "zig_semantic_decl", "{\"symbol\":\"main\",\"limit\":5}", expected, "semantic_decl_paths", scenarios);
    try assertToolPaths(allocator, io, port, 86, "zig_semantic_callers", "{\"symbol\":\"main\",\"limit\":5}", expected, "semantic_callers_paths", scenarios);
    try assertToolPaths(allocator, io, port, 87, "zig_static_fusion", "{\"query\":\"main\",\"limit\":5}", expected, "static_fusion_paths", scenarios);
    try assertToolPaths(allocator, io, port, 88, "zig_code_index_export", "{\"apply\":false,\"limit\":20}", expected, "code_index_export_paths", scenarios);
    try assertToolPaths(allocator, io, port, 89, "zig_scip_export", "{\"apply\":false,\"limit\":20}", expected, "scip_export_paths", scenarios);
    try assertToolPaths(allocator, io, port, 90, "zig_zlint", "{\"path\":\"src\"}", expected, "zlint_unavailable_paths", scenarios);
    try assertToolPaths(allocator, io, port, 91, "zig_zlint_sarif", "{\"path\":\"src\"}", expected, "zlint_sarif_unavailable_paths", scenarios);
    try assertToolPaths(allocator, io, port, 92, "zig_zlint_rules", "{}", expected, "zlint_rules_unavailable_paths", scenarios);
    try assertToolPaths(allocator, io, port, 93, "zig_zlint_fix", "{\"path\":\"src\",\"apply\":false}", expected, "zlint_fix_preview_paths", scenarios);
    try assertToolPaths(allocator, io, port, 94, "zig_lint_compare", "{\"zlint_findings\":\"[]\",\"zwanzig_findings\":\"[]\"}", expected, "lint_compare_paths", scenarios);
    try assertToolPaths(allocator, io, port, 95, "zig_lint_profile", "{}", expected, "lint_profile_paths", scenarios);
    try assertToolPaths(allocator, io, port, 96, "zig_lint_gate", "{\"findings\":\"[]\"}", expected, "lint_gate_paths", scenarios);
    try assertToolPaths(allocator, io, port, 97, "zig_lint_fix_plan", "{\"findings\":\"[]\"}", expected, "lint_fix_plan_paths", scenarios);
    try assertToolPaths(allocator, io, port, 98, "zig_lint_baseline", "{\"findings\":\"[]\",\"apply\":false}", expected, "lint_baseline_paths", scenarios);
    try assertToolPaths(allocator, io, port, 99, "zig_lint_suppressions", "{\"findings\":\"[]\"}", expected, "lint_suppressions_paths", scenarios);
    try assertToolPaths(allocator, io, port, 100, "zig_lint_trend", "{\"before\":\"[]\",\"after\":\"[]\"}", expected, "lint_trend_paths", scenarios);
}

/// Exercises workflow, environment, profile, and release-evidence tools.
pub fn runWorkflowAssertions(
    allocator: std.mem.Allocator,
    io: Io,
    port: u16,
    expected: JsonValue,
    scenarios: *usize,
) !void {
    try assertToolPaths(allocator, io, port, 14, "zig_package_cache_doctor", "{\"timeout_ms\":1000}", expected, "package_cache_doctor_paths", scenarios);
    try assertToolPaths(allocator, io, port, 15, "zigar_context_pack", "{\"mode\":\"tiny\"}", expected, "context_pack_paths", scenarios);
    try assertToolPaths(allocator, io, port, 16, "zigar_next_action", "{\"goal\":\"fix failing tests\",\"changed_files\":\"src/main.zig\"}", expected, "next_action_paths", scenarios);
    try assertToolPaths(allocator, io, port, 17, "zigar_agent_guide", "{\"client\":\"codex\",\"task\":\"patch\"}", expected, "agent_guide_paths", scenarios);
    try assertToolPaths(allocator, io, port, 18, "zigar_patch_guard", "{\"files\":\"src/main.zig zig-out/bin/zigar\"}", expected, "patch_guard_paths", scenarios);
    try assertToolPaths(allocator, io, port, 19, "zigar_failure_fusion", "{\"text\":\"src/main.zig:1:2: error: fixture failure\\n1/1 test.foo...FAIL\\n\"}", expected, "failure_fusion_paths", scenarios);
    try assertToolPaths(allocator, io, port, 20, "zigar_impact", "{\"files\":\"src/main.zig\",\"symbols\":\"main\",\"limit\":20}", expected, "impact_paths", scenarios);
    try assertToolPaths(allocator, io, port, 21, "zig_test_map", "{\"limit\":20}", expected, "test_map_paths", scenarios);
    try assertToolPaths(allocator, io, port, 22, "zig_test_select", "{\"files\":\"src/main.zig\",\"symbols\":\"main\",\"limit\":20}", expected, "test_select_paths", scenarios);
    try assertToolPaths(allocator, io, port, 23, "zig_public_api_diff", "{\"before\":\"pub fn oldName() void {}\\n\",\"after\":\"pub fn newName() void {}\\n\"}", expected, "public_api_diff_paths", scenarios);
    try assertToolPaths(allocator, io, port, 24, "zigar_project_profile", "{}", expected, "project_profile_paths", scenarios);
    try assertToolPaths(allocator, io, port, 57, "zigar_project_profile_v2", "{}", expected, "project_profile_v2_paths", scenarios);
    try assertToolPaths(allocator, io, port, 58, "zigar_profile_bootstrap", "{}", expected, "profile_bootstrap_paths", scenarios);
    try assertToolPaths(allocator, io, port, 59, "zigar_env_pack", "{\"probe_backends\":false,\"include_hashes\":false}", expected, "env_pack_paths", scenarios);
    try assertToolPaths(allocator, io, port, 60, "zigar_zvm_install_plan", "{\"version\":\"0.16.0\"}", expected, "zvm_install_plan_paths", scenarios);
    try assertToolPaths(allocator, io, port, 61, "zig_zls_match_check", "{\"probe_backends\":false}", expected, "zig_zls_match_paths", scenarios);
    try assertToolPaths(allocator, io, port, 62, "zig_toolchain_pin", "{\"apply\":false,\"zig_version\":\"0.16.0\",\"zls_version\":\"0.16.0\"}", expected, "toolchain_pin_paths", scenarios);
    try assertToolPaths(allocator, io, port, 63, "zigar_backend_install_plan", "{\"backend\":\"zflame\",\"manager\":\"manual\"}", expected, "backend_install_plan_paths", scenarios);
    try assertToolPaths(allocator, io, port, 64, "zigar_dev_env_generate", "{\"kind\":\"mise\",\"apply\":false}", expected, "dev_env_generate_paths", scenarios);
    try assertToolPaths(allocator, io, port, 65, "zigar_backend_conformance", "{\"backend\":\"zflame\",\"probe_backends\":false}", expected, "backend_conformance_paths", scenarios);
    try assertToolPaths(allocator, io, port, 66, "zigar_backend_evidence_pack", "{\"apply\":false}", expected, "backend_evidence_pack_paths", scenarios);
    try assertToolPaths(allocator, io, port, 25, "zigar_validate_patch", "{\"mode\":\"quick\",\"changed_files\":\"src/main.zig\",\"stop_on_failure\":true}", expected, "validate_patch_paths", scenarios);
    try assertToolPaths(allocator, io, port, 50, "zigar_result_shape", "{\"mode\":\"compact\"}", expected, "result_shape_paths", scenarios);
    try assertToolPaths(allocator, io, port, 51, "zigar_output_budget_plan", "{\"mode\":\"deep\",\"token_budget\":12,\"tool\":\"zig_check\"}", expected, "output_budget_paths", scenarios);
    try assertToolPaths(allocator, io, port, 52, "zigar_metrics_v2", "{}", expected, "metrics_v2_paths", scenarios);
    try assertToolPaths(allocator, io, port, 53, "zigar_command_provenance", "{\"tool\":\"zigar_artifact_prune\"}", expected, "command_provenance_paths", scenarios);
    try assertToolPaths(allocator, io, port, 54, "zigar_risk_audit", "{\"include_none\":false}", expected, "risk_audit_paths", scenarios);
    try assertToolPaths(allocator, io, port, 55, "zigar_docs_drift_check", "{\"mode\":\"compact\"}", expected, "docs_drift_paths", scenarios);
    try assertToolPaths(allocator, io, port, 56, "zigar_artifact_index", "{\"include_hashes\":false,\"limit\":1,\"mode\":\"compact\"}", expected, "artifact_index_paths", scenarios);
}

/// Asserts fixture-owned JSON paths for one tool call.
pub fn assertToolPaths(
    allocator: std.mem.Allocator,
    io: Io,
    port: u16,
    id: i64,
    tool_name: []const u8,
    args_json: []const u8,
    expected_root: JsonValue,
    expected_key: []const u8,
    scenario_count: *usize,
) !void {
    const tool_json = try smoke.callHttpToolJson(allocator, io, port, id, tool_name, args_json);
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

test "HTTP tool contract smoke helpers expose grouped assertions" {
    try std.testing.expect(@hasDecl(@This(), "runWorkflowAssertions"));
}
