const std = @import("std");

pub fn run(client: anytype) !void {
    const resources = try client.request("resources/list", null);
    defer client.allocator.free(resources);
    if (std.mem.indexOf(u8, resources, "zigars://jobs") == null) return error.AssertionFailed;
    if (std.mem.indexOf(u8, resources, "zigars://workspace/roots") == null) return error.AssertionFailed;
    const resource_templates = try client.request("resources/templates/list", null);
    defer client.allocator.free(resource_templates);
    if (std.mem.indexOf(u8, resource_templates, "zigars://artifacts/{sha}") == null) return error.AssertionFailed;

    const dynamic_resource = try client.request("resources/read", "{\"uri\":\"zigars://file/src/tests.zig/symbols\"}");
    defer client.allocator.free(dynamic_resource);
    if (std.mem.indexOf(u8, dynamic_resource, "zigars_dynamic_file_resource") == null) return error.AssertionFailed;
    const subscribed = try client.request("resources/subscribe", "{\"uri\":\"zigars://jobs\"}");
    defer client.allocator.free(subscribed);
    if (std.mem.indexOf(u8, subscribed, "{}") == null) return error.AssertionFailed;
    const unsubscribed = try client.request("resources/unsubscribe", "{\"uri\":\"zigars://jobs\"}");
    defer client.allocator.free(unsubscribed);
    if (std.mem.indexOf(u8, unsubscribed, "{}") == null) return error.AssertionFailed;

    const prompts = try client.request("prompts/list", null);
    defer client.allocator.free(prompts);
    if (std.mem.indexOf(u8, prompts, "zigars_compile_error_workflow") == null) return error.AssertionFailed;
    const completion = try client.request("completion/complete", "{\"argument\":{\"name\":\"command\",\"value\":\"b\"}}");
    defer client.allocator.free(completion);
    if (std.mem.indexOf(u8, completion, "build-test") == null) return error.AssertionFailed;
    const uri_completion = try client.request("completion/complete", "{\"argument\":{\"name\":\"uri\",\"value\":\"zigars://art\"}}");
    defer client.allocator.free(uri_completion);
    if (std.mem.indexOf(u8, uri_completion, "zigars://artifacts/{sha}") == null) return error.AssertionFailed;
    const paged_tools = try client.request("tools/list", "{\"limit\":2}");
    defer client.allocator.free(paged_tools);
    if (std.mem.indexOf(u8, paged_tools, "nextCursor") == null) return error.AssertionFailed;
    const tools = try client.request("tools/list", null);
    defer client.allocator.free(tools);
    if (std.mem.indexOf(u8, tools, "\"outputSchema\"") == null) return error.AssertionFailed;

    const workspace_map = try client.callTool("zigars_workspace_map", "{}");
    defer client.allocator.free(workspace_map);
    try client.expectPathString(workspace_map, "kind", "zigars_workspace_map");
    try client.expectPathString(workspace_map, "workspace.path_safety", "all file tools resolve paths inside configured_root");
    const roots_sync = try client.callTool("zigars_roots_sync", "{\"roots\":\"file://src\\n\",\"apply\":false}");
    defer client.allocator.free(roots_sync);
    try client.expectPathJson(roots_sync, "apply", .{ .bool = false });
    const symbols_resource = try client.callTool("zigars_resource_query", "{\"uri\":\"zigars://file/src/tests.zig/symbols\"}");
    defer client.allocator.free(symbols_resource);
    try client.expectPathString(symbols_resource, "kind", "zigars_resource_query");
    try client.expectPathString(symbols_resource, "resource_kind", "symbols");

    const prompt_pack = try client.callTool("zigars_prompt_pack", "{\"workflow\":\"zigars_test_workflow\"}");
    defer client.allocator.free(prompt_pack);
    try client.expectPathString(prompt_pack, "kind", "zigars_prompt_pack");
    try client.expectPathJson(prompt_pack, "workflow_count", .{ .integer = 1 });
    const agent_guide_v2 = try client.callTool("zigars_agent_guide_v2", "{\"client\":\"codex\",\"task\":\"test\"}");
    defer client.allocator.free(agent_guide_v2);
    try client.expectPathString(agent_guide_v2, "kind", "zigars_agent_guide_v2");
    const client_guide = try client.callTool("zigars_client_guide", "{\"client\":\"codex\"}");
    defer client.allocator.free(client_guide);
    try client.expectPathString(client_guide, "kind", "zigars_client_guide");

    const run_stream = try client.callTool("zigars_run_stream", "{\"command\":\"check\",\"file\":\"src/tests.zig\",\"timeout_ms\":10000}");
    defer client.allocator.free(run_stream);
    try client.expectPathString(run_stream, "kind", "zigars_run_stream");
    try client.expectPathString(run_stream, "status", "completed");
    const job_result = try client.callTool("zigars_job_result", "{\"job_id\":\"job-1\",\"limit\":5}");
    defer client.allocator.free(job_result);
    try client.expectPathString(job_result, "kind", "zigars_job_result");
    const tasks = try client.request("tasks/list", "{\"limit\":5}");
    defer client.allocator.free(tasks);
    if (std.mem.indexOf(u8, tasks, "job-1") == null) return error.AssertionFailed;
    const task = try client.request("tasks/get", "{\"taskId\":\"job-1\"}");
    defer client.allocator.free(task);
    if (std.mem.indexOf(u8, task, "\"taskId\":\"job-1\"") == null) return error.AssertionFailed;
    const task_result = try client.request("tasks/result", "{\"taskId\":\"job-1\"}");
    defer client.allocator.free(task_result);
    if (std.mem.indexOf(u8, task_result, "\"job_id\":\"job-1\"") == null) return error.AssertionFailed;
    const task_cancel = try client.request("tasks/cancel", "{\"taskId\":\"job-1\"}");
    defer client.allocator.free(task_cancel);
    if (std.mem.indexOf(u8, task_cancel, "\"taskId\":\"job-1\"") == null) return error.AssertionFailed;
}

test "stdio runtime UX fixture exposes run entrypoint" {
    try std.testing.expect(@hasDecl(@This(), "run"));
}
