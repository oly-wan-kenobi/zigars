const std = @import("std");
const subject = @import("validation_workflows.zig");
const zig_impact_semantic = subject.zig_impact_semantic;
const zig_test_select_semantic = subject.zig_test_select_semantic;
const zigar_validation_plan = subject.zigar_validation_plan;
const zigar_validation_run = subject.zigar_validation_run;
const zig_build_events = subject.zig_build_events;
const zig_test_events = subject.zig_test_events;
const zig_test_timing = subject.zig_test_timing;
const zigar_validation_history = subject.zigar_validation_history;
const zig_test_flake_history = subject.zig_test_flake_history;
const zig_failure_history = subject.zig_failure_history;
const zigar_session_snapshot = subject.zigar_session_snapshot;
const zigar_handoff_pack = subject.zigar_handoff_pack;
const zigar_decision_record = subject.zigar_decision_record;
const zigar_project_notes = subject.zigar_project_notes;
const zigar_project_memory = subject.zigar_project_memory;
const zigar_capability_match = subject.zigar_capability_match;
const zigar_tool_sequence_plan = subject.zigar_tool_sequence_plan;

test "validation workflow definitions expose semantic impact metadata" {
    try @import("std").testing.expect(zig_impact_semantic.description.len > 0);
}
