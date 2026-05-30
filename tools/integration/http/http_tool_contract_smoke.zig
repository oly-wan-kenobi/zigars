//! HTTP tool-result contract smoke: groups per-tool-family JSON path assertions
//! and re-exports the shared helper surface so http_smoke.zig has a single
//! contract-smoke entry point. Expected values stay in JSON fixtures; this
//! module only preserves call order and request IDs.

const std = @import("std");
const support = @import("http_tool_contract_support.zig");
const static_analysis = @import("http_tool_contract_smoke_b.zig");

const Io = std.Io;
const JsonValue = std.json.Value;

// Groups HTTP tool-result path assertions by ownership area. The expected
// values stay in JSON fixtures; this module only preserves call order and IDs.
/// Shared helper that verifies JSON paths for a successful tool response.
pub const assertToolPaths = support.assertToolPaths;
/// Shared helper that verifies JSON paths for an expected tool-error response.
pub const assertToolPathsIsError = support.assertToolPathsIsError;
/// Static-analysis contract scenarios re-exported for the HTTP smoke entrypoint.
pub const runStaticAnalysisAssertions = static_analysis.runStaticAnalysisAssertions;

/// Exercises workflow, environment, profile, and release-evidence tools.
pub fn runWorkflowAssertions(
    allocator: std.mem.Allocator,
    io: Io,
    port: u16,
    expected: JsonValue,
    scenarios: *usize,
) !void {
    try assertToolPaths(allocator, io, port, 14, "zig_package_cache_doctor", "{\"timeout_ms\":1000}", expected, "package_cache_doctor_paths", scenarios);
    try assertToolPaths(allocator, io, port, 15, "zigars_context_pack", "{\"mode\":\"tiny\"}", expected, "context_pack_paths", scenarios);
    try assertToolPaths(allocator, io, port, 16, "zigars_next_action", "{\"goal\":\"fix failing tests\",\"changed_files\":\"src/main.zig\"}", expected, "next_action_paths", scenarios);
    try assertToolPaths(allocator, io, port, 17, "zigars_agent_guide", "{\"client\":\"codex\",\"task\":\"patch\"}", expected, "agent_guide_paths", scenarios);
    try assertToolPaths(allocator, io, port, 18, "zigars_patch_guard", "{\"files\":\"src/main.zig zig-out/bin/zigars\"}", expected, "patch_guard_paths", scenarios);
    try assertToolPaths(allocator, io, port, 19, "zigars_failure_fusion", "{\"text\":\"src/main.zig:1:2: error: fixture failure\\n1/1 test.foo...FAIL\\n\"}", expected, "failure_fusion_paths", scenarios);
    try assertToolPaths(allocator, io, port, 20, "zigars_impact", "{\"files\":\"src/main.zig\",\"symbols\":\"main\",\"limit\":20}", expected, "impact_paths", scenarios);
    try assertToolPaths(allocator, io, port, 21, "zig_test_map", "{\"limit\":20}", expected, "test_map_paths", scenarios);
    try assertToolPaths(allocator, io, port, 22, "zig_test_select", "{\"files\":\"src/main.zig\",\"symbols\":\"main\",\"limit\":20}", expected, "test_select_paths", scenarios);
    try assertToolPaths(allocator, io, port, 23, "zig_public_api_diff", "{\"before\":\"pub fn oldName() void {}\\n\",\"after\":\"pub fn newName() void {}\\n\"}", expected, "public_api_diff_paths", scenarios);
    try assertToolPaths(allocator, io, port, 24, "zigars_project_profile", "{}", expected, "project_profile_paths", scenarios);
    try assertToolPaths(allocator, io, port, 57, "zigars_project_profile_v2", "{}", expected, "project_profile_v2_paths", scenarios);
    try assertToolPaths(allocator, io, port, 58, "zigars_profile_bootstrap", "{}", expected, "profile_bootstrap_paths", scenarios);
    try assertToolPaths(allocator, io, port, 59, "zigars_env_pack", "{\"probe_backends\":false,\"include_hashes\":false}", expected, "env_pack_paths", scenarios);
    try assertToolPaths(allocator, io, port, 60, "zigars_zvm_install_plan", "{\"version\":\"0.16.0\"}", expected, "zvm_install_plan_paths", scenarios);
    try assertToolPaths(allocator, io, port, 61, "zig_zls_match_check", "{\"probe_backends\":false}", expected, "zig_zls_match_paths", scenarios);
    try assertToolPaths(allocator, io, port, 62, "zig_toolchain_pin", "{\"apply\":false,\"zig_version\":\"0.16.0\",\"zls_version\":\"0.16.0\"}", expected, "toolchain_pin_paths", scenarios);
    try assertToolPaths(allocator, io, port, 63, "zigars_backend_install_plan", "{\"backend\":\"zflame\",\"manager\":\"manual\"}", expected, "backend_install_plan_paths", scenarios);
    try assertToolPaths(allocator, io, port, 64, "zigars_dev_env_generate", "{\"kind\":\"mise\",\"apply\":false}", expected, "dev_env_generate_paths", scenarios);
    try assertToolPaths(allocator, io, port, 65, "zigars_backend_conformance", "{\"backend\":\"zflame\",\"probe_backends\":false}", expected, "backend_conformance_paths", scenarios);
    try assertToolPaths(allocator, io, port, 66, "zigars_backend_evidence_pack", "{\"apply\":false}", expected, "backend_evidence_pack_paths", scenarios);
    try assertToolPaths(allocator, io, port, 25, "zigars_validate_patch", "{\"mode\":\"quick\",\"changed_files\":\"src/main.zig\",\"stop_on_failure\":true}", expected, "validate_patch_paths", scenarios);
    try assertToolPaths(allocator, io, port, 50, "zigars_result_shape", "{\"mode\":\"compact\"}", expected, "result_shape_paths", scenarios);
    try assertToolPaths(allocator, io, port, 51, "zigars_output_budget_plan", "{\"mode\":\"deep\",\"token_budget\":12,\"tool\":\"zig_check\"}", expected, "output_budget_paths", scenarios);
    try assertToolPaths(allocator, io, port, 52, "zigars_metrics_v2", "{}", expected, "metrics_v2_paths", scenarios);
    try assertToolPaths(allocator, io, port, 53, "zigars_command_provenance", "{\"tool\":\"zigars_artifact_prune\"}", expected, "command_provenance_paths", scenarios);
    try assertToolPaths(allocator, io, port, 54, "zigars_risk_audit", "{\"include_none\":false}", expected, "risk_audit_paths", scenarios);
    try assertToolPaths(allocator, io, port, 55, "zigars_docs_drift_check", "{\"mode\":\"compact\"}", expected, "docs_drift_paths", scenarios);
    try assertToolPaths(allocator, io, port, 56, "zigars_artifact_index", "{\"include_hashes\":false,\"limit\":1,\"mode\":\"compact\"}", expected, "artifact_index_paths", scenarios);
}

test "HTTP tool contract smoke helpers expose grouped assertions" {
    try std.testing.expect(@hasDecl(@This(), "runWorkflowAssertions"));
    try std.testing.expect(@hasDecl(@This(), "runStaticAnalysisAssertions"));
}
