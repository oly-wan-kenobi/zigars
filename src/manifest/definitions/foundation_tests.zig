const std = @import("std");
const subject = @import("foundation.zig");
const zigar_artifact_index = subject.zigar_artifact_index;
const zigar_artifact_read = subject.zigar_artifact_read;
const zigar_session_view = subject.zigar_session_view;
const zigar_artifact_prune = subject.zigar_artifact_prune;
const zigar_metrics_v2 = subject.zigar_metrics_v2;
const zigar_backend_health_history = subject.zigar_backend_health_history;
const zigar_zls_timeline = subject.zigar_zls_timeline;
const zigar_tool_latency = subject.zigar_tool_latency;
const zigar_trust_report = subject.zigar_trust_report;
const zigar_command_provenance = subject.zigar_command_provenance;
const zigar_risk_audit = subject.zigar_risk_audit;
const zigar_clean_tree_gate = subject.zigar_clean_tree_gate;
const zigar_result_shape = subject.zigar_result_shape;
const zigar_output_budget_plan = subject.zigar_output_budget_plan;
const zigar_docs_drift_check = subject.zigar_docs_drift_check;
const zigar_release_claim_check = subject.zigar_release_claim_check;
const zigar_tool_index_check = subject.zigar_tool_index_check;

test "foundation definitions expose artifact metadata" {
    try @import("std").testing.expect(zigar_artifact_index.description.len > 0);
    try std.testing.expect(zigar_session_view.read_only);
    try std.testing.expectEqual(.artifact_registry, zigar_session_view.group);
}
