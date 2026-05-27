const std = @import("std");
const subject = @import("agent.zig");
const zigars_context_pack = subject.zigars_context_pack;
const zigars_next_action = subject.zigars_next_action;
const zigars_agent_guide = subject.zigars_agent_guide;
const zigars_validate_patch = subject.zigars_validate_patch;
const zigars_failure_fusion = subject.zigars_failure_fusion;
const zigars_impact = subject.zigars_impact;
const zigars_project_profile = subject.zigars_project_profile;
const zigars_patch_guard = subject.zigars_patch_guard;

test "agent definitions expose workflow metadata" {
    try @import("std").testing.expect(zigars_context_pack.description.len > 0);
}
