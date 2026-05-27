const std = @import("std");
const subject = @import("runtime_ux.zig");
const zigars_job_start = subject.zigars_job_start;
const zigars_job_status = subject.zigars_job_status;
const zigars_job_result = subject.zigars_job_result;
const zigars_job_cancel = subject.zigars_job_cancel;
const zigars_cancel_status = subject.zigars_cancel_status;
const zigars_run_stream = subject.zigars_run_stream;
const zigars_run_events = subject.zigars_run_events;
const zigars_resource_query = subject.zigars_resource_query;
const zigars_resource_subscribe = subject.zigars_resource_subscribe;
const zigars_resource_unsubscribe = subject.zigars_resource_unsubscribe;
const zigars_roots_sync = subject.zigars_roots_sync;
const zigars_workspace_map = subject.zigars_workspace_map;
const zigars_workspace_select = subject.zigars_workspace_select;
const zigars_agent_guide_v2 = subject.zigars_agent_guide_v2;
const zigars_client_guide = subject.zigars_client_guide;
const zigars_prompt_pack = subject.zigars_prompt_pack;

test "runtime UX definitions expose job metadata" {
    try @import("std").testing.expect(zigars_job_start.description.len > 0);
}
