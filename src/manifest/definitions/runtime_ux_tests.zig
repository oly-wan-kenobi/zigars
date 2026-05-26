const std = @import("std");
const subject = @import("runtime_ux.zig");
const zigar_job_start = subject.zigar_job_start;
const zigar_job_status = subject.zigar_job_status;
const zigar_job_result = subject.zigar_job_result;
const zigar_job_cancel = subject.zigar_job_cancel;
const zigar_cancel_status = subject.zigar_cancel_status;
const zigar_run_stream = subject.zigar_run_stream;
const zigar_run_events = subject.zigar_run_events;
const zigar_resource_query = subject.zigar_resource_query;
const zigar_resource_subscribe = subject.zigar_resource_subscribe;
const zigar_resource_unsubscribe = subject.zigar_resource_unsubscribe;
const zigar_roots_sync = subject.zigar_roots_sync;
const zigar_workspace_map = subject.zigar_workspace_map;
const zigar_workspace_select = subject.zigar_workspace_select;
const zigar_agent_guide_v2 = subject.zigar_agent_guide_v2;
const zigar_client_guide = subject.zigar_client_guide;
const zigar_prompt_pack = subject.zigar_prompt_pack;

test "runtime UX definitions expose job metadata" {
    try @import("std").testing.expect(zigar_job_start.description.len > 0);
}
