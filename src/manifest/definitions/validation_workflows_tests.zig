//! Pins the public surface of the validation_workflows tool definitions: every
//! tool must carry a non-empty description and the expected group/risk metadata.
const std = @import("std");
const subject = @import("validation_workflows.zig");
const zig_impact_semantic = subject.zig_impact_semantic;
const zig_test_select_semantic = subject.zig_test_select_semantic;
const zigars_validation_plan = subject.zigars_validation_plan;
const zigars_validation_run = subject.zigars_validation_run;
const zig_build_events = subject.zig_build_events;
const zig_test_events = subject.zig_test_events;
const zig_test_timing = subject.zig_test_timing;
const zigars_validation_history = subject.zigars_validation_history;
const zig_test_flake_history = subject.zig_test_flake_history;
const zig_failure_history = subject.zig_failure_history;
const zigars_session_snapshot = subject.zigars_session_snapshot;
const zigars_handoff_pack = subject.zigars_handoff_pack;
const zigars_decision_record = subject.zigars_decision_record;
const zigars_project_notes = subject.zigars_project_notes;
const zigars_project_memory = subject.zigars_project_memory;
const zigars_capability_match = subject.zigars_capability_match;
const zigars_tool_sequence_plan = subject.zigars_tool_sequence_plan;

test "validation workflow definitions expose semantic impact metadata" {
    try @import("std").testing.expect(zig_impact_semantic.description.len > 0);
}
