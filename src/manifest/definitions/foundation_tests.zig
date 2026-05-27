const std = @import("std");
const subject = @import("foundation.zig");
const zigars_artifact_index = subject.zigars_artifact_index;
const zigars_artifact_read = subject.zigars_artifact_read;
const zigars_session_view = subject.zigars_session_view;
const zigars_artifact_prune = subject.zigars_artifact_prune;
const zigars_metrics_v2 = subject.zigars_metrics_v2;
const zigars_backend_health_history = subject.zigars_backend_health_history;
const zigars_zls_timeline = subject.zigars_zls_timeline;
const zigars_tool_latency = subject.zigars_tool_latency;
const zigars_trust_report = subject.zigars_trust_report;
const zigars_command_provenance = subject.zigars_command_provenance;
const zigars_risk_audit = subject.zigars_risk_audit;
const zigars_clean_tree_gate = subject.zigars_clean_tree_gate;
const zigars_result_shape = subject.zigars_result_shape;
const zigars_output_budget_plan = subject.zigars_output_budget_plan;
const zigars_docs_drift_check = subject.zigars_docs_drift_check;
const zigars_release_claim_check = subject.zigars_release_claim_check;
const zigars_tool_index_check = subject.zigars_tool_index_check;

test "foundation definitions expose artifact metadata" {
    try @import("std").testing.expect(zigars_artifact_index.description.len > 0);
    try std.testing.expect(zigars_session_view.read_only);
    try std.testing.expectEqual(.artifact_registry, zigars_session_view.group);
}
