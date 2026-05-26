const std = @import("std");
const subject = @import("agent.zig");
const zigar_context_pack = subject.zigar_context_pack;
const zigar_next_action = subject.zigar_next_action;
const zigar_agent_guide = subject.zigar_agent_guide;
const zigar_validate_patch = subject.zigar_validate_patch;
const zigar_failure_fusion = subject.zigar_failure_fusion;
const zigar_impact = subject.zigar_impact;
const zigar_project_profile = subject.zigar_project_profile;
const zigar_patch_guard = subject.zigar_patch_guard;

test "agent definitions expose workflow metadata" {
    try @import("std").testing.expect(zigar_context_pack.description.len > 0);
}
