//! Runtime UX workflows for process-local jobs, events, resource queries, and
//! subscription state surfaced through MCP-facing tool handlers.
const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const zig_analysis = @import("../../../domain/zig/analysis.zig");
const workspace_scans = @import("../static_analysis/workspace_scans.zig");

pub const max_resource_read: usize = 1024 * 1024;
pub const max_roots: usize = 16;

pub const RuntimeUxError = ports.PortError || error{
    InvalidArguments,
    MissingFile,
    MissingCatalog,
};

pub const RunJobRequest = struct {
    tool_name: []const u8,
    command: []const u8,
    file: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    timeout_ms: i64,
    include_events: bool = false,
};

pub const JobResultRequest = struct {
    job_id: []const u8,
    cursor: u64 = 0,
    limit: usize = 25,
    mode: []const u8 = "standard",
};

pub const EventsRequest = struct {
    job_id: ?[]const u8 = null,
    cursor: u64 = 0,
    limit: usize = 50,
};

pub const ResourceQueryRequest = struct {
    uri: []const u8,
    cursor: u64 = 0,
    limit: usize = 50,
    mode: []const u8 = "standard",
};

pub fn runJobValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, request: RunJobRequest) RuntimeUxError!std.json.Value {
    // Jobs are tracked in process-local session state; subprocess lifetime is
    // summarized into immutable tails so clients can poll deterministically.
    try context.runtime_session.ensureDefaultRoot(context.workspace.root);
    const plan = try buildRunPlan(allocator, context, request);
    const title = try std.fmt.allocPrint(allocator, "{s} {s}", .{ request.tool_name, request.command });
    const job = try context.runtime_session.startJob(title, plan.command_text, request.timeout_ms);

    const result = context.command_runner.run(allocator, .{
        .argv = plan.argv,
        .cwd = context.workspace.root,
        .timeout_ms = if (request.timeout_ms > 0) @intCast(request.timeout_ms) else null,
        .provenance = request.tool_name,
    }) catch |err| {
        _ = context.runtime_session.failJob(job.id, @errorName(err), 0) catch {};
        return commandErrorJobValue(allocator, context, request.tool_name, job, plan.argv, request.timeout_ms, err, request.include_events);
    };
    defer result.deinit(allocator);

    const term = result.effectiveTerm();
    const stdout_tail = allocator.dupe(u8, result.stdout) catch return error.OutOfMemory;
    const stderr_tail = allocator.dupe(u8, result.stderr) catch return error.OutOfMemory;
    const finished = try context.runtime_session.finishJob(job.id, .{
        .status = if (!term.failed() and !result.timed_out) .completed else .failed,
        .ok = !term.failed() and !result.timed_out,
        .duration_ms = @intCast(result.duration_ms),
        .term = term.name(),
        .exit_code = term.exitCode(),
        .stdout_tail = stdout_tail,
        .stderr_tail = stderr_tail,
        .stdout_truncated = result.stdout_truncated,
        .stderr_truncated = result.stderr_truncated,
    });

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = request.tool_name });
    try obj.put(allocator, "ok", .{ .bool = finished.ok });
    try obj.put(allocator, "job_id", .{ .string = finished.id });
    try obj.put(allocator, "status", .{ .string = finished.status.text() });
    try obj.put(allocator, "job", try jobValue(allocator, finished));
    try obj.put(allocator, "cwd", .{ .string = context.workspace.root });
    try obj.put(allocator, "argv", try argvValue(allocator, plan.argv));
    try obj.put(allocator, "result_available", .{ .bool = true });
    try obj.put(allocator, "stdout_tail", .{ .string = finished.stdout_tail });
    try obj.put(allocator, "stderr_tail", .{ .string = finished.stderr_tail });
    try obj.put(allocator, "stdout_truncated", .{ .bool = finished.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = finished.stderr_truncated });
    if (request.include_events) try obj.put(allocator, "events", try eventsPageValue(allocator, context, finished.id, 0, 50));
    try obj.put(allocator, "next_tools", try stringArrayValue(allocator, &.{ "zigar_job_status", "zigar_job_result", "zigar_run_events" }));
    try obj.put(allocator, "limitations", try runtimeLimitationsValue(allocator));
    return .{ .object = obj };
}

pub fn jobStatusValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, job_id: []const u8) RuntimeUxError!std.json.Value {
    const job = try context.runtime_session.jobById(job_id);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_job_status" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "job", try jobValue(allocator, job));
    try obj.put(allocator, "result_available", .{ .bool = job.status.terminal() });
    try obj.put(allocator, "events_cursor", .{ .string = try cursorString(allocator, try context.runtime_session.eventCount()) });
    try obj.put(allocator, "limitations", try runtimeLimitationsValue(allocator));
    return .{ .object = obj };
}

pub fn jobResultValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, request: JobResultRequest) RuntimeUxError!std.json.Value {
    const job = try context.runtime_session.jobById(request.job_id);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_job_result" });
    try obj.put(allocator, "ok", .{ .bool = job.ok });
    try obj.put(allocator, "job", try jobValue(allocator, job));
    try obj.put(allocator, "stdout_tail", .{ .string = job.stdout_tail });
    try obj.put(allocator, "stderr_tail", .{ .string = job.stderr_tail });
    try obj.put(allocator, "stdout_truncated", .{ .bool = job.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = job.stderr_truncated });
    try obj.put(allocator, "events", try eventsPageValue(allocator, context, job.id, request.cursor, request.limit));
    try obj.put(allocator, "omitted_sections", try omittedSectionsValue(allocator, request.mode, &.{ "full_stdout", "full_stderr", "live_process_handle" }));
    try obj.put(allocator, "limitations", try runtimeLimitationsValue(allocator));
    return .{ .object = obj };
}

pub fn jobCancelValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, job_id: []const u8, reason: []const u8) RuntimeUxError!std.json.Value {
    const before = try context.runtime_session.jobById(job_id);
    const job = try context.runtime_session.cancelJob(job_id, reason);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_job_cancel" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "cancelled", .{ .bool = !before.status.terminal() });
    try obj.put(allocator, "status", .{ .string = job.status.text() });
    try obj.put(allocator, "job", try jobValue(allocator, job));
    try obj.put(allocator, "note", .{ .string = if (before.status.terminal()) "job was already terminal; cancellation was recorded for auditability" else "job marked cancelled in process-local state" });
    try obj.put(allocator, "limitations", try runtimeLimitationsValue(allocator));
    return .{ .object = obj };
}

pub fn cancelStatusValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, job_id: ?[]const u8) RuntimeUxError!std.json.Value {
    var jobs = std.json.Array.init(allocator);
    if (job_id) |id| {
        try jobs.append(try cancellationValue(allocator, try context.runtime_session.jobById(id)));
    } else {
        const count = try context.runtime_session.jobCount();
        var index: usize = 0;
        while (index < count) : (index += 1) try jobs.append(try cancellationValue(allocator, try context.runtime_session.jobAt(index)));
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_cancel_status" });
    try obj.put(allocator, "jobs", .{ .array = jobs });
    try obj.put(allocator, "job_count", .{ .integer = @intCast(jobs.items.len) });
    return .{ .object = obj };
}

pub fn runEventsValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, request: EventsRequest) RuntimeUxError!std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_run_events" });
    if (request.job_id) |id| try obj.put(allocator, "job_id", .{ .string = id }) else try obj.put(allocator, "job_id", .null);
    try obj.put(allocator, "events", try eventsPageValue(allocator, context, request.job_id, request.cursor, request.limit));
    return .{ .object = obj };
}

pub fn resourceQueryValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, request: ResourceQueryRequest) RuntimeUxError!std.json.Value {
    if (std.mem.startsWith(u8, request.uri, "zigar://file/")) return fileResourceQueryValue(allocator, context, request.uri, request.mode);
    if (std.mem.eql(u8, request.uri, "zigar://jobs")) return jobsQueryValue(allocator, context, request.cursor, request.limit, request.mode);
    if (std.mem.eql(u8, request.uri, "zigar://run/events")) {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "kind", .{ .string = "zigar_resource_query" });
        try obj.put(allocator, "uri", .{ .string = request.uri });
        try obj.put(allocator, "resource", try eventsPageValue(allocator, context, null, request.cursor, request.limit));
        return .{ .object = obj };
    }
    if (std.mem.eql(u8, request.uri, "zigar://workspace/roots")) return workspaceMapResultValue(allocator, context, "zigar_resource_query", request.uri);
    if (std.mem.eql(u8, request.uri, "zigar://prompts")) return promptPackValue(allocator, null, request.mode);
    return error.InvalidArguments;
}

pub fn resourceSubscribeValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) RuntimeUxError!std.json.Value {
    const sub = try context.runtime_session.subscribe(uri);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_resource_subscribe" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "subscription", try subscriptionValue(allocator, sub));
    try obj.put(allocator, "notification_method", .{ .string = "notifications/resources/updated" });
    try obj.put(allocator, "scope", .{ .string = "process_local" });
    return .{ .object = obj };
}

pub fn resourceUnsubscribeValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, subscription_id: ?[]const u8, uri: ?[]const u8) RuntimeUxError!std.json.Value {
    if (subscription_id == null and uri == null) return error.InvalidArguments;
    const sub = try context.runtime_session.unsubscribe(subscription_id orelse "", uri);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_resource_unsubscribe" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "subscription", try subscriptionValue(allocator, sub));
    return .{ .object = obj };
}

pub fn rootsSyncValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, roots: []const u8, apply: bool) RuntimeUxError!std.json.Value {
    try context.runtime_session.ensureDefaultRoot(context.workspace.root);
    const before = try context.runtime_session.rootCount();
    const preview = try rootsPreviewValue(allocator, roots, context.workspace.root);
    if (apply) try context.runtime_session.syncRoots(context.workspace.root, roots, true);
    const after = try context.runtime_session.rootCount();
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_roots_sync" });
    try obj.put(allocator, "apply", .{ .bool = apply });
    try obj.put(allocator, "changed", .{ .bool = apply and before != after });
    try obj.put(allocator, "preview_roots", preview);
    try obj.put(allocator, "workspace", try workspaceMapValue(allocator, context));
    try obj.put(allocator, "note", .{ .string = "workspace roots are process-local guidance; file tools continue enforcing the configured zigar workspace path policy" });
    return .{ .object = obj };
}

pub fn workspaceMapResultValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, kind: []const u8, uri: ?[]const u8) RuntimeUxError!std.json.Value {
    try context.runtime_session.ensureDefaultRoot(context.workspace.root);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = kind });
    if (uri) |u| try obj.put(allocator, "uri", .{ .string = u });
    try obj.put(allocator, "workspace", try workspaceMapValue(allocator, context));
    return .{ .object = obj };
}

pub fn workspaceSelectValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, workspace_id: []const u8, apply: bool) RuntimeUxError!std.json.Value {
    try context.runtime_session.ensureDefaultRoot(context.workspace.root);
    const root = try context.runtime_session.selectRoot(workspace_id, apply);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_workspace_select" });
    try obj.put(allocator, "apply", .{ .bool = apply });
    try obj.put(allocator, "selected", try rootValue(allocator, root));
    try obj.put(allocator, "workspace", try workspaceMapValue(allocator, context));
    try obj.put(allocator, "note", .{ .string = "selection is process-local guidance; file access remains constrained to the configured zigar workspace" });
    return .{ .object = obj };
}

pub fn agentGuideV2Value(allocator: std.mem.Allocator, client: []const u8, task: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_agent_guide_v2" });
    try obj.put(allocator, "client", .{ .string = client });
    try obj.put(allocator, "task", .{ .string = task });
    try obj.put(allocator, "principles", try stringArrayValue(allocator, &.{
        "discover with zigar_capabilities, zigar_tool_index, and zigar_workspace_map before choosing tools",
        "use profile, backend, and toolchain setup tools before claiming an environment is ready",
        "prefer zigar_job_start or zigar_run_stream for bounded build and test evidence",
        "use zigar_resource_query and MCP resources for symbols, imports, diagnostics, jobs, events, and roots",
        "treat apply=true as the only write gate for generated setup, profile, artifact, and edit operations",
    }));
    try obj.put(allocator, "core_sequences", try workflowSummariesValue(allocator));
    try obj.put(allocator, "next_tools", try stringArrayValue(allocator, &.{ "zigar_workspace_map", "zigar_prompt_pack", "zigar_client_guide", "zigar_run_stream" }));
    try obj.put(allocator, "workflow_contract", try workflowContractValue(allocator, "workspace/tool/profile/runtime discovery", "deterministic tool sequence guidance", "medium", "guidance is not evidence that commands passed", "collect job or tool evidence before reporting success", "stop when requested evidence exists or a structured tool_error blocks progress", &.{ "zigar_job_result", "zigar_run_events" }));
    return .{ .object = obj };
}

pub fn clientGuideValue(allocator: std.mem.Allocator, client: []const u8, task: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_client_guide" });
    try obj.put(allocator, "client", .{ .string = client });
    try obj.put(allocator, "task", .{ .string = task });
    try obj.put(allocator, "supported_surfaces", try stringArrayValue(allocator, &.{ "tools", "resources", "resource templates", "resource subscriptions", "prompts", "completion", "tasks", "roots guidance" }));
    try obj.put(allocator, "recommended_startup", try stringArrayValue(allocator, &.{ "initialize and inspect capabilities", "call tools/list with pagination when needed", "call resources/list and resources/templates/list", "call prompts/list", "call zigar_workspace_map" }));
    try obj.put(allocator, "runtime_notes", try stringArrayValue(allocator, &.{
        "tasks and jobs are process-local and retained in bounded rings",
        "resources/subscribe acknowledges subscriptions and zigar_resource_subscribe exposes inspectable subscription ids",
        "completion/complete returns values for zigar resource URIs, prompt names, workflow names, clients, and allow-listed command names",
        "roots tools guide zigar responses but do not expand workspace path access",
    }));
    return .{ .object = obj };
}

pub fn promptPackValue(allocator: std.mem.Allocator, workflow: ?[]const u8, mode: []const u8) !std.json.Value {
    var workflows = std.json.Array.init(allocator);
    for (workflow_defs) |def| {
        if (workflow) |wanted| if (!std.mem.eql(u8, wanted, def.name)) continue;
        try workflows.append(try workflowValue(allocator, def));
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_prompt_pack" });
    if (workflow) |wanted| try obj.put(allocator, "workflow", .{ .string = wanted }) else try obj.put(allocator, "workflow", .null);
    try obj.put(allocator, "workflows", .{ .array = workflows });
    try obj.put(allocator, "workflow_count", .{ .integer = @intCast(workflows.items.len) });
    try obj.put(allocator, "omitted_sections", try omittedSectionsValue(allocator, mode, &.{}));
    return .{ .object = obj };
}

pub fn workspaceResourceText(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext) ![]const u8 {
    return std.fmt.allocPrint(allocator, "workspace={s}\ncache={s}\nzig={s}\nzwanzig={s}\nzflame={s}\ndiff_folded={s}\n", .{
        context.workspace.root,
        context.workspace.cache_root,
        context.tool_paths.zig,
        context.tool_paths.zwanzig,
        context.tool_paths.zflame,
        context.tool_paths.diff_folded,
    });
}

pub fn zlsStatusResourceValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "status", .{ .string = context.zls_state.status });
    try obj.put(allocator, "configured_path", .{ .string = context.tool_paths.zls });
    try obj.put(allocator, "request_timeout_ms", .{ .integer = context.timeouts.zls_ms });
    try obj.put(allocator, "restart_attempts", .{ .integer = @intCast(context.zls_state.restart_attempts) });
    try obj.put(allocator, "running", .{ .bool = context.zls_state.connected() });
    try obj.put(allocator, "document_sync", .{ .bool = false });
    try obj.put(allocator, "document_state", .null);
    try obj.put(allocator, "initialize_response_present", .{ .bool = context.zls_state.initialize_response != null });
    try obj.put(allocator, "last_failure", if (context.zls_state.last_failure) |failure| .{ .string = failure } else .null);
    try obj.put(allocator, "resolution", .{ .string = if (context.zls_state.connected()) "ZLS-backed tools are available" else "confirm --zls-path points to a compatible ZLS binary; command-backed Zig tools remain available" });
    return .{ .object = obj };
}

pub fn catalogResourceText(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext) RuntimeUxError![]const u8 {
    const catalog = context.tool_catalog orelse return error.MissingCatalog;
    const rendered = try catalog.text(allocator);
    if (rendered.owns_text) return rendered.text;
    return allocator.dupe(u8, rendered.text) catch return error.OutOfMemory;
}

pub fn importGraphResourceText(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext) RuntimeUxError![]const u8 {
    var graph = try workspace_scans.importGraph(allocator, .{
        .workspace = context.workspace,
        .workspace_store = context.workspace_store,
        .workspace_scanner = context.workspace_scanner,
    }, .{ .limit = workspace_scans.default_scan_limit });
    defer graph.deinit(allocator);
    return workspace_scans.importGraphText(allocator, graph);
}

pub fn metricsResourceValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "command_calls", .{ .integer = if (context.counters.command_calls) |counter| @intCast(counter.*) else 0 });
    try obj.put(allocator, "zls_requests", .{ .integer = if (context.counters.zls_requests) |counter| @intCast(counter.*) else 0 });
    try obj.put(allocator, "tool_errors", .{ .integer = if (context.counters.tool_errors) |counter| @intCast(counter.*) else 0 });
    try obj.put(allocator, "zls_status", .{ .string = context.zls_state.status });
    try obj.put(allocator, "zls", try zlsStatusResourceValue(allocator, context));
    try obj.put(allocator, "zls_running", .{ .bool = context.zls_state.connected() });
    try obj.put(allocator, "zls_restart_attempts", .{ .integer = @intCast(context.zls_state.restart_attempts) });
    try obj.put(allocator, "zls_last_failure", if (context.zls_state.last_failure) |failure| .{ .string = failure } else .null);
    try obj.put(allocator, "workspace", .{ .string = context.workspace.root });
    try obj.put(allocator, "backend_probe_cache", try backendCacheValue(allocator, context.caches.backend_probe));
    try obj.put(allocator, "analysis_cache", try analysisCacheStatusValue(allocator, context.caches.analysis));
    return .{ .object = obj };
}

pub fn jobsResourceValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext) RuntimeUxError!std.json.Value {
    var jobs = std.json.Array.init(allocator);
    const count = try context.runtime_session.jobCount();
    var index: usize = 0;
    while (index < count) : (index += 1) try jobs.append(try jobResourceValue(allocator, try context.runtime_session.jobAt(index)));
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_jobs_resource" });
    try obj.put(allocator, "jobs", .{ .array = jobs });
    try obj.put(allocator, "job_count", .{ .integer = @intCast(count) });
    try obj.put(allocator, "retention", .{ .string = "process_local_bounded_ring" });
    return .{ .object = obj };
}

pub fn runEventsResourceValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext) RuntimeUxError!std.json.Value {
    var events = std.json.Array.init(allocator);
    const count = try context.runtime_session.eventCount();
    var sequence: u64 = 1;
    while (sequence <= count) : (sequence += 1) {
        const event = context.runtime_session.eventAtSequence(sequence) catch continue;
        try events.append(try eventValue(allocator, event));
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_run_events_resource" });
    try obj.put(allocator, "events", .{ .array = events });
    try obj.put(allocator, "event_count", .{ .integer = @intCast(count) });
    try obj.put(allocator, "retention", .{ .string = "process_local_bounded_ring" });
    return .{ .object = obj };
}

pub fn workspaceRootsResourceValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext) RuntimeUxError!std.json.Value {
    try context.runtime_session.ensureDefaultRoot(context.workspace.root);
    var roots = std.json.Array.init(allocator);
    const count = try context.runtime_session.rootCount();
    var index: usize = 0;
    while (index < count) : (index += 1) try roots.append(try rootValue(allocator, try context.runtime_session.rootAt(index)));
    const selected = try context.runtime_session.selectedRootIndex();
    const selected_root = try context.runtime_session.rootAt(selected);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_workspace_roots_resource" });
    try obj.put(allocator, "configured_root", .{ .string = context.workspace.root });
    try obj.put(allocator, "roots", .{ .array = roots });
    try obj.put(allocator, "selected_root_id", .{ .string = selected_root.id });
    try obj.put(allocator, "path_safety", .{ .string = "file tools resolve paths inside configured_root" });
    return .{ .object = obj };
}

pub fn dynamicResourceValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) RuntimeUxError!std.json.Value {
    const prefix = "zigar://file/";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.NotFound;
    const rest = uri[prefix.len..];
    const slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse return error.InvalidArguments;
    const path = rest[0..slash];
    const kind = rest[slash + 1 ..];
    if (path.len == 0) return error.InvalidArguments;
    const read = try context.workspace_store.read(allocator, .{
        .path = path,
        .max_bytes = max_resource_read,
        .provenance = "runtime_ux.dynamic_resource",
    });
    defer read.deinit(allocator);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_dynamic_file_resource" });
    try obj.put(allocator, "uri", .{ .string = uri });
    try obj.put(allocator, "path", .{ .string = path });
    try obj.put(allocator, "resource_kind", .{ .string = kind });
    if (std.mem.eql(u8, kind, "symbols")) {
        const resource = astDeclSummaryJson(allocator, path, read.bytes) catch |err| return analysisError(err);
        try obj.put(allocator, "resource", resource);
    } else if (std.mem.eql(u8, kind, "imports")) {
        const resource = astImportsJson(allocator, path, read.bytes) catch |err| return analysisError(err);
        try obj.put(allocator, "resource", resource);
    } else if (std.mem.eql(u8, kind, "diagnostics")) {
        const resource = diagnosticsResourceValue(allocator, path) catch |err| return analysisError(err);
        try obj.put(allocator, "resource", resource);
    } else {
        return error.InvalidArguments;
    }
    return .{ .object = obj };
}

fn analysisError(err: anyerror) RuntimeUxError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidArguments,
    };
}

pub fn profilePromptText() []const u8 {
    return "Use zigar_workspace_info, zig_profile_plan, zig_profile_run, zig_flamegraph, and zig_flamegraph_diff to build a deterministic Zig profiling workflow. Do not edit source files unless an explicit tool argument requires apply=true.";
}

pub fn workflowPromptText(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "zigar_compile_error_workflow")) return "Use zigar_run_stream or zig_check evidence, then zig_compile_error_index, zig_explain_errors, and zigar_failure_fusion before proposing the smallest fix.";
    if (std.mem.eql(u8, name, "zigar_refactor_workflow")) return "Use owner, symbol, import, impact, public API, and changed-file tools before editing; validate with format, check, tests, and patch guard evidence.";
    if (std.mem.eql(u8, name, "zigar_api_change_workflow")) return "Snapshot public API, compare API changes, inspect references and import edges, then validate with bounded build and test evidence.";
    if (std.mem.eql(u8, name, "zigar_release_workflow")) return "Check profile, toolchain, backend conformance, docs drift, release claims, JSON fixtures, smoke fixtures, and release-check evidence before reporting release readiness.";
    if (std.mem.eql(u8, name, "zigar_perf_workflow")) return "Use profiling plan, run, flamegraph, and flamegraph diff tools while keeping profiler backend availability explicit.";
    return "Discover relevant tests, run the narrowest bounded zigar job, triage failures, and broaden only after local evidence is clean.";
}

const RunPlan = struct {
    argv: []const []const u8,
    command_text: []const u8,
};

fn buildRunPlan(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, request: RunJobRequest) RuntimeUxError!RunPlan {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    try argv.append(allocator, context.tool_paths.zig);
    if (std.mem.eql(u8, request.command, "build")) {
        try argv.append(allocator, "build");
    } else if (std.mem.eql(u8, request.command, "build-test")) {
        try argv.append(allocator, "build");
        try argv.append(allocator, "test");
    } else if (std.mem.eql(u8, request.command, "test")) {
        const file = request.file orelse return error.MissingFile;
        const rel = try checkedRelativePath(allocator, context, file);
        try argv.append(allocator, "test");
        try argv.append(allocator, rel);
    } else if (std.mem.eql(u8, request.command, "check")) {
        const file = request.file orelse return error.MissingFile;
        const rel = try checkedRelativePath(allocator, context, file);
        try argv.append(allocator, "ast-check");
        try argv.append(allocator, rel);
    } else if (std.mem.eql(u8, request.command, "fmt-check")) {
        const file = request.file orelse return error.MissingFile;
        const rel = try checkedRelativePath(allocator, context, file);
        try argv.append(allocator, "fmt");
        try argv.append(allocator, "--check");
        try argv.append(allocator, rel);
    } else {
        return error.InvalidArguments;
    }
    try argv.appendSlice(allocator, request.extra_args);
    const owned_argv = try argv.toOwnedSlice(allocator);
    return .{ .argv = owned_argv, .command_text = try commandString(allocator, owned_argv) };
}

fn checkedRelativePath(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, path: []const u8) RuntimeUxError![]const u8 {
    const resolved = try context.workspace_store.resolve(allocator, .{ .path = path, .provenance = "runtime_ux.run_plan" });
    defer resolved.deinit(allocator);
    return allocator.dupe(u8, path) catch return error.OutOfMemory;
}

fn commandErrorJobValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, tool_name: []const u8, job: ports.RuntimeJobSnapshot, argv: []const []const u8, timeout_ms: i64, err: anyerror, include_events: bool) !std.json.Value {
    const failed = context.runtime_session.jobById(job.id) catch job;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "job_id", .{ .string = job.id });
    try obj.put(allocator, "status", .{ .string = failed.status.text() });
    try obj.put(allocator, "job", try jobValue(allocator, failed));
    try obj.put(allocator, "argv", try argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = errorKind(err) });
    if (include_events) try obj.put(allocator, "events", try eventsPageValue(allocator, context, job.id, 0, 50));
    try obj.put(allocator, "limitations", try runtimeLimitationsValue(allocator));
    return .{ .object = obj };
}

fn fileResourceQueryValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8, mode: []const u8) RuntimeUxError!std.json.Value {
    const dynamic = try dynamicResourceValue(allocator, context, uri);
    const obj = dynamic.object;
    var out = std.json.ObjectMap.empty;
    errdefer out.deinit(allocator);
    try out.put(allocator, "kind", .{ .string = "zigar_resource_query" });
    try out.put(allocator, "uri", .{ .string = uri });
    try out.put(allocator, "resource_kind", obj.get("resource_kind") orelse .null);
    try out.put(allocator, "path", obj.get("path") orelse .null);
    try out.put(allocator, "resource", obj.get("resource") orelse .null);
    try out.put(allocator, "omitted_sections", try omittedSectionsValue(allocator, mode, &.{"full_file_text"}));
    return .{ .object = out };
}

fn workspaceMapValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext) RuntimeUxError!std.json.Value {
    var roots = std.json.Array.init(allocator);
    const root_count = try context.runtime_session.rootCount();
    var index: usize = 0;
    while (index < root_count) : (index += 1) try roots.append(try rootValue(allocator, try context.runtime_session.rootAt(index)));
    var entry_points = std.json.Array.init(allocator);
    if (try workspacePathExists(allocator, context, "build.zig")) try entry_points.append(.{ .string = "build.zig" });
    if (try workspacePathExists(allocator, context, "build.zig.zon")) try entry_points.append(.{ .string = "build.zig.zon" });
    if (try workspacePathExists(allocator, context, "src")) try entry_points.append(.{ .string = "src" });
    const selected = try context.runtime_session.selectedRootIndex();
    const selected_root = try context.runtime_session.rootAt(selected);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "configured_root", .{ .string = context.workspace.root });
    try obj.put(allocator, "cache_root", .{ .string = context.workspace.cache_root });
    try obj.put(allocator, "roots", .{ .array = roots });
    try obj.put(allocator, "root_count", .{ .integer = @intCast(root_count) });
    try obj.put(allocator, "selected_root_id", .{ .string = selected_root.id });
    try obj.put(allocator, "entry_points", .{ .array = entry_points });
    try obj.put(allocator, "path_safety", .{ .string = "all file tools resolve paths inside configured_root" });
    return .{ .object = obj };
}

fn jobsQueryValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, cursor: u64, limit: usize, mode: []const u8) RuntimeUxError!std.json.Value {
    var page = std.json.Array.init(allocator);
    const count = try context.runtime_session.jobCount();
    var index: usize = @intCast(@min(cursor, count));
    const end = @min(count, index + limit);
    while (index < end) : (index += 1) try page.append(try jobValue(allocator, try context.runtime_session.jobAt(index)));
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_resource_query" });
    try obj.put(allocator, "uri", .{ .string = "zigar://jobs" });
    try obj.put(allocator, "jobs", .{ .array = page });
    try obj.put(allocator, "job_count", .{ .integer = @intCast(count) });
    if (end < count) try obj.put(allocator, "nextCursor", .{ .string = try cursorString(allocator, end) });
    try obj.put(allocator, "omitted_sections", try omittedSectionsValue(allocator, mode, &.{ "full_stdout", "full_stderr" }));
    return .{ .object = obj };
}

fn jobResourceValue(allocator: std.mem.Allocator, job: ports.RuntimeJobSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "job_id", .{ .string = job.id });
    try obj.put(allocator, "label", .{ .string = job.label });
    try obj.put(allocator, "command", .{ .string = job.command });
    try obj.put(allocator, "status", .{ .string = job.status.text() });
    try obj.put(allocator, "ok", .{ .bool = job.ok });
    try obj.put(allocator, "duration_ms", .{ .integer = job.duration_ms });
    try obj.put(allocator, "stdout_tail", .{ .string = job.stdout_tail });
    try obj.put(allocator, "stderr_tail", .{ .string = job.stderr_tail });
    return .{ .object = obj };
}

fn jobValue(allocator: std.mem.Allocator, job: ports.RuntimeJobSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "job_id", .{ .string = job.id });
    try obj.put(allocator, "label", .{ .string = job.label });
    try obj.put(allocator, "command", .{ .string = job.command });
    try obj.put(allocator, "status", .{ .string = job.status.text() });
    try obj.put(allocator, "ok", .{ .bool = job.ok });
    try obj.put(allocator, "created_sequence", .{ .integer = @intCast(job.created_sequence) });
    try obj.put(allocator, "updated_sequence", .{ .integer = @intCast(job.updated_sequence) });
    try obj.put(allocator, "duration_ms", .{ .integer = job.duration_ms });
    try obj.put(allocator, "timeout_ms", .{ .integer = job.timeout_ms });
    try obj.put(allocator, "term", .{ .string = job.term });
    if (job.exit_code) |code| try obj.put(allocator, "exit_code", .{ .integer = code }) else try obj.put(allocator, "exit_code", .null);
    try obj.put(allocator, "cancellation_requested", .{ .bool = job.cancellation_requested });
    try obj.put(allocator, "cancellation_reason", .{ .string = job.cancellation_reason });
    return .{ .object = obj };
}

fn cancellationValue(allocator: std.mem.Allocator, job: ports.RuntimeJobSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "job_id", .{ .string = job.id });
    try obj.put(allocator, "status", .{ .string = job.status.text() });
    try obj.put(allocator, "terminal", .{ .bool = job.status.terminal() });
    try obj.put(allocator, "cancellation_requested", .{ .bool = job.cancellation_requested });
    try obj.put(allocator, "cancellation_reason", .{ .string = job.cancellation_reason });
    return .{ .object = obj };
}

fn eventsPageValue(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, job_filter: ?[]const u8, cursor: u64, limit: usize) RuntimeUxError!std.json.Value {
    const count = try context.runtime_session.eventCount();
    var sequence = cursor + 1;
    var events = std.json.Array.init(allocator);
    var appended: usize = 0;
    while (sequence <= count and appended < limit) : (sequence += 1) {
        const event = context.runtime_session.eventAtSequence(sequence) catch continue;
        if (job_filter) |filter| if (!std.mem.eql(u8, event.job_id, filter)) continue;
        try events.append(try eventValue(allocator, event));
        appended += 1;
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "items", .{ .array = events });
    try obj.put(allocator, "cursor", .{ .string = try cursorString(allocator, cursor) });
    if (sequence <= count) try obj.put(allocator, "nextCursor", .{ .string = try cursorString(allocator, sequence - 1) });
    try obj.put(allocator, "event_count", .{ .integer = @intCast(count) });
    try obj.put(allocator, "retention", .{ .string = "bounded_ring" });
    return .{ .object = obj };
}

fn eventValue(allocator: std.mem.Allocator, event: ports.RuntimeEventSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "sequence", .{ .integer = @intCast(event.sequence) });
    try obj.put(allocator, "job_id", .{ .string = event.job_id });
    try obj.put(allocator, "event", .{ .string = event.event });
    try obj.put(allocator, "stream", .{ .string = event.stream });
    try obj.put(allocator, "message", .{ .string = event.message });
    try obj.put(allocator, "text", .{ .string = event.text });
    try obj.put(allocator, "elapsed_ms", .{ .integer = event.elapsed_ms });
    return .{ .object = obj };
}

fn rootValue(allocator: std.mem.Allocator, root: ports.RuntimeRootSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "id", .{ .string = root.id });
    try obj.put(allocator, "path", .{ .string = root.path });
    try obj.put(allocator, "uri", .{ .string = root.uri });
    try obj.put(allocator, "name", .{ .string = root.name });
    try obj.put(allocator, "selected", .{ .bool = root.selected });
    return .{ .object = obj };
}

fn subscriptionValue(allocator: std.mem.Allocator, sub: ports.RuntimeSubscriptionSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "subscription_id", .{ .string = sub.id });
    try obj.put(allocator, "uri", .{ .string = sub.uri });
    try obj.put(allocator, "active", .{ .bool = sub.active });
    try obj.put(allocator, "created_sequence", .{ .integer = @intCast(sub.created_sequence) });
    return .{ .object = obj };
}

fn rootsPreviewValue(allocator: std.mem.Allocator, roots_text: []const u8, default_root: []const u8) !std.json.Value {
    var roots = std.json.Array.init(allocator);
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, roots_text, "\n\r\t ");
    while (tokens.next()) |token| {
        if (count >= max_roots) break;
        const path = if (std.mem.startsWith(u8, token, "file://")) token["file://".len..] else token;
        if (path.len == 0) continue;
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "id", .{ .string = try std.fmt.allocPrint(allocator, "root-{d}", .{count + 1}) });
        try item.put(allocator, "path", .{ .string = path });
        try item.put(allocator, "name", .{ .string = std.fs.path.basename(path) });
        try item.put(allocator, "selected", .{ .bool = count == 0 });
        try roots.append(.{ .object = item });
        count += 1;
    }
    if (count == 0) {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "id", .{ .string = "root-1" });
        try item.put(allocator, "path", .{ .string = default_root });
        try item.put(allocator, "name", .{ .string = "default" });
        try item.put(allocator, "selected", .{ .bool = true });
        try roots.append(.{ .object = item });
    }
    return .{ .array = roots };
}

const WorkflowDef = struct {
    name: []const u8,
    title: []const u8,
    prompt: []const u8,
    tools: []const []const u8,
};

const workflow_defs = [_]WorkflowDef{
    .{ .name = "zigar_compile_error_workflow", .title = "Compile Error Workflow", .prompt = "Use build or check evidence, index compiler errors, inspect context around the primary diagnostic, then validate the smallest fix with a bounded rerun.", .tools = &.{ "zigar_run_stream", "zig_compile_error_index", "zig_explain_errors", "zigar_failure_fusion", "zigar_job_result" } },
    .{ .name = "zigar_test_workflow", .title = "Test Workflow", .prompt = "Discover relevant tests, run the narrowest bounded test command, triage failures, and broaden only after local evidence is clean.", .tools = &.{ "zig_test_map", "zig_test_select", "zigar_run_stream", "zig_test_failure_triage", "zigar_job_result" } },
    .{ .name = "zigar_refactor_workflow", .title = "Refactor Workflow", .prompt = "Map owners, imports, symbols, public API, and changed files before editing; validate with format, check, tests, and patch guard evidence.", .tools = &.{ "zig_file_owner", "zigar_resource_query", "zig_changed_files_plan", "zig_public_api_diff", "zigar_validate_patch" } },
    .{ .name = "zigar_api_change_workflow", .title = "API Change Workflow", .prompt = "Snapshot public declarations, compare impact, inspect references/imports, and produce compatibility evidence before claiming an API change is safe.", .tools = &.{ "zig_public_api", "zig_public_api_diff", "zig_references", "zigar_impact", "zigar_run_stream" } },
    .{ .name = "zigar_release_workflow", .title = "Release Workflow", .prompt = "Check profile, toolchain, backend conformance, docs drift, release claims, JSON fixtures, smoke fixtures, and final build/test evidence.", .tools = &.{ "zigar_profile_validate", "zig_toolchain_pin_check", "zigar_backend_conformance", "zigar_docs_drift_check", "zigar_release_claim_check" } },
    .{ .name = "zigar_perf_workflow", .title = "Performance Workflow", .prompt = "Plan a reproducible benchmark, run profiling tools with explicit commands, generate flamegraphs, compare captures, and keep profiler availability explicit.", .tools = &.{ "zig_profile_plan", "zig_profile_run", "zig_flamegraph", "zig_flamegraph_diff", "zigar_backend_verify" } },
};

fn workflowValue(allocator: std.mem.Allocator, def: WorkflowDef) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "name", .{ .string = def.name });
    try obj.put(allocator, "title", .{ .string = def.title });
    try obj.put(allocator, "prompt", .{ .string = def.prompt });
    try obj.put(allocator, "tools", try stringArrayValue(allocator, def.tools));
    return .{ .object = obj };
}

fn workflowSummariesValue(allocator: std.mem.Allocator) !std.json.Value {
    var workflows = std.json.Array.init(allocator);
    for (workflow_defs) |def| try workflows.append(try workflowValue(allocator, def));
    return .{ .array = workflows };
}

fn workflowContractValue(
    allocator: std.mem.Allocator,
    input_basis: []const u8,
    evidence_required: []const u8,
    confidence: []const u8,
    limitation: []const u8,
    fail_closed: []const u8,
    stop_rule: []const u8,
    follow_up_tools: []const []const u8,
) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "input_basis", .{ .string = input_basis });
    try obj.put(allocator, "evidence_required", .{ .string = evidence_required });
    try obj.put(allocator, "confidence", .{ .string = confidence });
    try obj.put(allocator, "limitation", .{ .string = limitation });
    try obj.put(allocator, "fail_closed", .{ .string = fail_closed });
    try obj.put(allocator, "stop_rule", .{ .string = stop_rule });
    try obj.put(allocator, "follow_up_tools", try stringArrayValue(allocator, follow_up_tools));
    return .{ .object = obj };
}

fn runtimeLimitationsValue(allocator: std.mem.Allocator) !std.json.Value {
    return stringArrayValue(allocator, &.{
        "job and event state is process-local and not persisted across server restarts",
        "allow-listed run tools execute synchronously before returning a retained job result",
        "cancellation records intent for retained jobs but cannot kill a command that has already completed",
        "stdout and stderr are stored as bounded tails",
    });
}

fn diagnosticsResourceValue(allocator: std.mem.Allocator, file: []const u8) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_file_diagnostics_resource" });
    try obj.put(allocator, "file", .{ .string = file });
    try obj.put(allocator, "source", .{ .string = "static_resource_query" });
    try obj.put(allocator, "diagnostics", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "diagnostic_count", .{ .integer = 0 });
    try obj.put(allocator, "confidence", .{ .string = "low" });
    try obj.put(allocator, "recommended_cross_check", try stringArrayValue(allocator, &.{ "zig_diagnostics_all", "zig_check", "zigar_run_stream" }));
    try obj.put(allocator, "note", .{ .string = "dynamic diagnostics resource is read-only and does not execute Zig or require ZLS; use compiler or ZLS tools for authoritative diagnostics" });
    return .{ .object = obj };
}

fn astDeclSummaryJson(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) !std.json.Value {
    var summary = try zig_analysis.parseSourceSummary(allocator, file, contents);
    defer summary.deinit(allocator);
    var declarations = std.json.Array.init(allocator);
    for (summary.declarations) |decl| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "line", .{ .integer = @intCast(decl.line) });
        try item.put(allocator, "kind", try jsonString(allocator, decl.kind));
        try item.put(allocator, "name", if (decl.name) |name| try jsonString(allocator, name) else .null);
        try item.put(allocator, "public", .{ .bool = decl.public });
        try item.put(allocator, "comptime", .{ .bool = decl.is_comptime });
        try item.put(allocator, "depth", .{ .integer = @intCast(decl.depth) });
        try item.put(allocator, "text", try jsonString(allocator, decl.signature));
        try declarations.append(.{ .object = item });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_ast_decl_summary" });
    try obj.put(allocator, "file", .{ .string = file });
    try putParseMetadata(allocator, &obj, summary.parse);
    try obj.put(allocator, "declarations", .{ .array = declarations });
    try obj.put(allocator, "skipped_files", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "skipped_file_count", .{ .integer = 0 });
    return .{ .object = obj };
}

fn astImportsJson(allocator: std.mem.Allocator, file: []const u8, contents: []const u8) !std.json.Value {
    var summary = try zig_analysis.parseSourceSummary(allocator, file, contents);
    defer summary.deinit(allocator);
    var imports = std.json.Array.init(allocator);
    for (summary.imports) |import_item| {
        var item = std.json.ObjectMap.empty;
        try item.put(allocator, "file", try jsonString(allocator, import_item.file));
        try item.put(allocator, "line", .{ .integer = @intCast(import_item.line) });
        try item.put(allocator, "import", try jsonString(allocator, import_item.import));
        try item.put(allocator, "alias", if (import_item.alias) |alias| try jsonString(allocator, alias) else .null);
        try item.put(allocator, "declaration", try jsonString(allocator, import_item.declaration));
        try imports.append(.{ .object = item });
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zig_ast_imports" });
    try obj.put(allocator, "file", .{ .string = file });
    try putParseMetadata(allocator, &obj, summary.parse);
    try obj.put(allocator, "imports", .{ .array = imports });
    try obj.put(allocator, "skipped_files", .{ .array = std.json.Array.init(allocator) });
    try obj.put(allocator, "skipped_file_count", .{ .integer = 0 });
    return .{ .object = obj };
}

fn jsonString(allocator: std.mem.Allocator, value: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, value) };
}

fn putParseMetadata(allocator: std.mem.Allocator, obj: *std.json.ObjectMap, parse: zig_analysis.ParseMetadata) !void {
    try obj.put(allocator, "parse_status", .{ .string = switch (parse.status) {
        .ok => "ok",
        .syntax_errors => "syntax_errors",
        .heuristic_fallback => "heuristic_fallback",
    } });
    try obj.put(allocator, "partial_result", .{ .bool = parse.partial_result });
    try obj.put(allocator, "result_complete", .{ .bool = parse.result_complete });
    try obj.put(allocator, "parse_error_count", .{ .integer = parse.parse_error_count });
}

fn backendCacheValue(allocator: std.mem.Allocator, snapshot: app_context.BackendProbeCacheSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig", try cachedProbeValue(allocator, snapshot.zig));
    try obj.put(allocator, "zls", try cachedProbeValue(allocator, snapshot.zls));
    try obj.put(allocator, "zlint", try cachedProbeValue(allocator, snapshot.zlint));
    try obj.put(allocator, "zwanzig", try cachedProbeValue(allocator, snapshot.zwanzig));
    try obj.put(allocator, "zflame", try cachedProbeValue(allocator, snapshot.zflame));
    try obj.put(allocator, "diff_folded", try cachedProbeValue(allocator, snapshot.diff_folded));
    return .{ .object = obj };
}

fn cachedProbeValue(allocator: std.mem.Allocator, probed: bool) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "probed", .{ .bool = probed });
    try obj.put(allocator, "ok", .null);
    try obj.put(allocator, "status", .{ .string = if (probed) "cached" else "not probed" });
    try obj.put(allocator, "resolution", .{ .string = "call zigar_doctor with probe_backends=true to cache backend availability" });
    return .{ .object = obj };
}

fn analysisCacheStatusValue(allocator: std.mem.Allocator, snapshot: app_context.CacheSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "present", .{ .bool = snapshot.cached });
    try obj.put(allocator, "signature", .{ .string = try std.fmt.allocPrint(allocator, "{x:0>16}", .{snapshot.signature}) });
    try obj.put(allocator, "hits", .{ .integer = @intCast(snapshot.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(snapshot.refreshes) });
    try obj.put(allocator, "bytes", .{ .integer = 0 });
    return .{ .object = obj };
}

fn workspacePathExists(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, path: []const u8) RuntimeUxError!bool {
    const exists = context.workspace_store.exists(allocator, .{
        .path = path,
        .provenance = "runtime_ux.workspace_map",
    }) catch return false;
    return exists.exists;
}

fn omittedSectionsValue(allocator: std.mem.Allocator, mode: []const u8, sections: []const []const u8) !std.json.Value {
    var arr = std.json.Array.init(allocator);
    if (std.mem.eql(u8, mode, "deep")) return .{ .array = arr };
    for (sections) |section| try arr.append(.{ .string = section });
    return .{ .array = arr };
}

fn argvValue(allocator: std.mem.Allocator, argv: []const []const u8) !std.json.Value {
    return stringArrayValue(allocator, argv);
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

fn commandString(allocator: std.mem.Allocator, argv: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, " ", argv);
}

fn cursorString(allocator: std.mem.Allocator, cursor: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{cursor});
}

fn errorKind(err: anyerror) []const u8 {
    return switch (err) {
        error.RequestTimeout, error.Timeout => "timeout",
        error.NotFound, error.FileNotFound => "not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        error.PathOutsideWorkspace, error.EmptyPath => "workspace_path",
        error.InvalidRequest, error.InvalidArguments => "invalid_data",
        else => "execution_failed",
    };
}

const test_fakes = @import("../../../testing/fakes/root.zig");

const NonOwningCatalog = struct {
    text_value: []const u8,
    calls: usize = 0,

    fn port(self: *NonOwningCatalog) ports.ToolCatalog {
        return .{
            .ptr = self,
            .vtable = &.{ .text = text },
        };
    }

    fn text(ptr: *anyopaque, _: std.mem.Allocator) ports.PortError!ports.ToolCatalogText {
        const self: *NonOwningCatalog = @ptrCast(@alignCast(ptr));
        self.calls += 1;
        return .{ .text = self.text_value, .owns_text = false };
    }
};

fn runtimeUxTestContext(
    command_runner: *test_fakes.FakeCommandRunner,
    workspace_store: *test_fakes.FakeWorkspaceStore,
    workspace_scanner: *test_fakes.FakeWorkspaceScanner,
    runtime_session: *test_fakes.FakeRuntimeSession,
    tool_catalog: ?ports.ToolCatalog,
) app_context.RuntimeUxContext {
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache" },
        .tool_paths = .{ .zig = "/bin/zig", .zls = "/bin/zls", .zwanzig = "/bin/zwanzig", .zflame = "/bin/zflame", .diff_folded = "/bin/diff-folded" },
        .timeouts = .{ .command_ms = 1000, .zls_ms = 2000 },
        .zls_state = .{ .status = "connected", .initialize_response = "{}", .last_failure = "old failure", .restart_attempts = 2 },
        .command_runner = command_runner.port(),
        .workspace_store = workspace_store.port(),
        .workspace_scanner = workspace_scanner.port(),
        .runtime_session = runtime_session.port(),
        .tool_catalog = tool_catalog,
    };
}

fn expectRuntimeWorkspaceMapExists(workspace: *test_fakes.FakeWorkspaceStore) !void {
    try workspace.expectExists(.{ .path = "build.zig", .provenance = "runtime_ux.workspace_map" }, .{ .exists = true, .kind = .file });
    try workspace.expectExists(.{ .path = "build.zig.zon", .provenance = "runtime_ux.workspace_map" }, .{ .exists = true, .kind = .file });
    try workspace.expectExists(.{ .path = "src", .provenance = "runtime_ux.workspace_map" }, .{ .exists = false });
}

fn seedRuntimeJob(session: *test_fakes.FakeRuntimeSession) !void {
    const port = session.port();
    try port.ensureDefaultRoot("/repo");
    const job = try port.startJob("seed", "/bin/zig build", 1000);
    _ = try port.finishJob(job.id, .{
        .status = .completed,
        .ok = true,
        .duration_ms = 9,
        .term = "exited",
        .exit_code = 0,
        .stdout_tail = "ok\n",
        .stderr_tail = "",
        .stdout_truncated = false,
        .stderr_truncated = false,
    });
}

test "runtime UX covers resource variants and non owning catalog text" {
    var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var session = test_fakes.FakeRuntimeSession{};
    defer session.deinit(std.testing.allocator);
    var catalog = NonOwningCatalog{ .text_value = "catalog text" };
    const context = runtimeUxTestContext(&commands, &workspace, &scanner, &session, catalog.port());

    try workspace.expectResolve(.{ .path = "src/main.zig", .provenance = "runtime_ux.run_plan" }, "/repo/src/main.zig");
    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "test", "src/main.zig", "--summary", "all" },
        .cwd = "/repo",
        .timeout_ms = 123,
        .provenance = "zigar_job_start",
    }, .{ .exit_code = 0, .term = .{ .exited = 0 }, .stdout = "test ok\n", .stderr = "", .duration_ms = 5 });

    try workspace.expectRead(.{ .path = "src/main.zig", .max_bytes = max_resource_read, .provenance = "runtime_ux.dynamic_resource" },
        \\const std = @import("std");
        \\pub fn main() void {}
    );
    try workspace.expectRead(.{ .path = "src/main.zig", .max_bytes = max_resource_read, .provenance = "runtime_ux.dynamic_resource" },
        \\const std = @import("std");
        \\pub fn main() void {}
    );
    try expectRuntimeWorkspaceMapExists(&workspace);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const run = try runJobValue(allocator, context, .{
        .tool_name = "zigar_job_start",
        .command = "test",
        .file = "src/main.zig",
        .extra_args = &.{ "--summary", "all" },
        .timeout_ms = 123,
    });
    try std.testing.expect(run.object.get("ok").?.bool);

    const symbols = try dynamicResourceValue(allocator, context, "zigar://file/src/main.zig/symbols");
    try std.testing.expectEqualStrings("symbols", symbols.object.get("resource_kind").?.string);

    const diagnostics = try resourceQueryValue(allocator, context, .{ .uri = "zigar://file/src/main.zig/diagnostics" });
    try std.testing.expectEqualStrings("diagnostics", diagnostics.object.get("resource_kind").?.string);

    const empty_roots = try rootsSyncValue(allocator, context, "", false);
    try std.testing.expectEqual(@as(usize, 1), empty_roots.object.get("preview_roots").?.array.items.len);

    const map = try workspaceMapResultValue(allocator, context, "zigar_workspace_map", "zigar://workspace/roots");
    try std.testing.expectEqualStrings("zigar://workspace/roots", map.object.get("uri").?.string);

    const catalog_text = try catalogResourceText(allocator, context);
    try std.testing.expectEqualStrings("catalog text", catalog_text);
    try std.testing.expectEqual(@as(usize, 1), catalog.calls);

    const subscribed = try resourceSubscribeValue(allocator, context, "zigar://jobs");
    const sub_uri = subscribed.object.get("subscription").?.object.get("uri").?.string;
    const unsubscribed = try resourceUnsubscribeValue(allocator, context, null, sub_uri);
    try std.testing.expect(!unsubscribed.object.get("subscription").?.object.get("active").?.bool);

    const cancel_status = try cancelStatusValue(allocator, context, "job-1");
    try std.testing.expectEqual(@as(i64, 1), cancel_status.object.get("job_count").?.integer);

    try commands.verify();
    try workspace.verify();
}

test "runtime UX private helpers classify analysis and error kinds" {
    try std.testing.expectEqual(error.OutOfMemory, analysisError(error.OutOfMemory));
    try std.testing.expectEqual(error.InvalidArguments, analysisError(error.SyntaxError));
    try std.testing.expectEqualStrings("timeout", errorKind(error.Timeout));
    try std.testing.expectEqualStrings("not_found", errorKind(error.FileNotFound));
    try std.testing.expectEqualStrings("permission", errorKind(error.AccessDenied));
    try std.testing.expectEqualStrings("workspace_path", errorKind(error.PathOutsideWorkspace));
    try std.testing.expectEqualStrings("invalid_data", errorKind(error.InvalidRequest));
    try std.testing.expectEqualStrings("execution_failed", errorKind(error.UnexpectedCall));
}

test "runtime UX value builders clean partial objects on allocation failure" {
    const source =
        \\const std = @import("std");
        \\pub fn main() void {}
    ;
    const def = WorkflowDef{
        .name = "wf",
        .title = "Workflow",
        .prompt = "prompt",
        .tools = &.{ "zig", "build" },
    };

    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        const allocator = failing.allocator();

        if (agentGuideV2Value(allocator, "codex", "fix")) |_| {} else |err| try expectRuntimeOom(err);
        if (clientGuideValue(allocator, "mcp", "discover")) |_| {} else |err| try expectRuntimeOom(err);
        if (promptPackValue(allocator, null, "standard")) |_| {} else |err| try expectRuntimeOom(err);
        if (workflowValue(allocator, def)) |_| {} else |err| try expectRuntimeOom(err);
        if (workflowContractValue(allocator, "input", "evidence", "medium", "limit", "closed", "stop", &.{"tool"})) |_| {} else |err| try expectRuntimeOom(err);
        if (diagnosticsResourceValue(allocator, "src/main.zig")) |_| {} else |err| try expectRuntimeOom(err);
        if (astDeclSummaryJson(allocator, "src/main.zig", source)) |_| {} else |err| try expectRuntimeOom(err);
        if (astImportsJson(allocator, "src/main.zig", source)) |_| {} else |err| try expectRuntimeOom(err);
        if (backendCacheValue(allocator, .{ .zig = true, .zls = true, .zlint = true })) |_| {} else |err| try expectRuntimeOom(err);
        if (cachedProbeValue(allocator, true)) |_| {} else |err| try expectRuntimeOom(err);
        if (analysisCacheStatusValue(allocator, .{ .cached = true, .signature = 0xabc, .hits = 1, .refreshes = 2 })) |_| {} else |err| try expectRuntimeOom(err);
        if (rootsPreviewValue(allocator, "", "/repo")) |_| {} else |err| try expectRuntimeOom(err);
    }
}

test "runtime UX context values clean partial objects on allocation failure" {
    var fail_index: usize = 0;
    while (fail_index < 96) : (fail_index += 1) {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        const allocator = failing.allocator();

        var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
        defer commands.deinit();
        var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
        defer workspace.deinit();
        var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
        defer scanner.deinit();
        var session = test_fakes.FakeRuntimeSession{};
        defer session.deinit(std.testing.allocator);
        var catalog = NonOwningCatalog{ .text_value = "catalog" };
        var context = runtimeUxTestContext(&commands, &workspace, &scanner, &session, catalog.port());
        var command_calls: u64 = 1;
        var zls_requests: u64 = 2;
        var tool_errors: u64 = 3;
        context.counters.command_calls = &command_calls;
        context.counters.zls_requests = &zls_requests;
        context.counters.tool_errors = &tool_errors;
        context.caches.backend_probe.zig = true;
        context.caches.backend_probe.zls = true;
        context.caches.analysis = .{ .cached = true, .signature = 0x123, .hits = 2, .refreshes = 1 };

        try seedRuntimeJob(&session);
        _ = try context.runtime_session.subscribe("zigar://jobs");

        try commands.expectRun(.{
            .argv = &.{ "/bin/zig", "build" },
            .cwd = "/repo",
            .timeout_ms = 1000,
            .provenance = "zigar_job_start",
        }, .{ .exit_code = 0, .term = .{ .exited = 0 }, .stdout = "ok\n", .stderr = "", .duration_ms = 4 });
        try commands.expectRunError(.{
            .argv = &.{ "/bin/zig", "build" },
            .cwd = "/repo",
            .timeout_ms = 1000,
            .provenance = "zigar_run_stream",
        }, error.RequestTimeout);
        try workspace.expectRead(.{ .path = "src/main.zig", .max_bytes = max_resource_read, .provenance = "runtime_ux.dynamic_resource" },
            \\const std = @import("std");
            \\pub fn main() void {}
        );
        try workspace.expectRead(.{ .path = "src/main.zig", .max_bytes = max_resource_read, .provenance = "runtime_ux.dynamic_resource" },
            \\const std = @import("std");
            \\pub fn main() void {}
        );
        try expectRuntimeWorkspaceMapExists(&workspace);
        try expectRuntimeWorkspaceMapExists(&workspace);
        try expectRuntimeWorkspaceMapExists(&workspace);

        if (runJobValue(allocator, context, .{ .tool_name = "zigar_job_start", .command = "build", .timeout_ms = 1000, .include_events = true })) |_| {} else |err| try expectRuntimeOom(err);
        if (runJobValue(allocator, context, .{ .tool_name = "zigar_run_stream", .command = "build", .timeout_ms = 1000, .include_events = true })) |_| {} else |err| try expectRuntimeOom(err);
        if (jobStatusValue(allocator, context, "job-1")) |_| {} else |err| try expectRuntimeOom(err);
        if (jobResultValue(allocator, context, .{ .job_id = "job-1", .limit = 1 })) |_| {} else |err| try expectRuntimeOom(err);
        if (jobCancelValue(allocator, context, "job-1", "stop")) |_| {} else |err| try expectRuntimeOom(err);
        if (cancelStatusValue(allocator, context, null)) |_| {} else |err| try expectRuntimeOom(err);
        if (runEventsValue(allocator, context, .{ .limit = 1 })) |_| {} else |err| try expectRuntimeOom(err);
        if (resourceQueryValue(allocator, context, .{ .uri = "zigar://run/events", .limit = 1 })) |_| {} else |err| try expectRuntimeOom(err);
        if (resourceQueryValue(allocator, context, .{ .uri = "zigar://jobs", .limit = 1 })) |_| {} else |err| try expectRuntimeOom(err);
        if (resourceSubscribeValue(allocator, context, "zigar://run/events")) |_| {} else |err| try expectRuntimeOom(err);
        if (resourceUnsubscribeValue(allocator, context, null, "zigar://jobs")) |_| {} else |err| try expectRuntimeOom(err);
        if (rootsSyncValue(allocator, context, "file:///repo\n/tmp/alt", false)) |_| {} else |err| try expectRuntimeOom(err);
        if (workspaceMapResultValue(allocator, context, "zigar_workspace_map", null)) |_| {} else |err| try expectRuntimeOom(err);
        if (workspaceSelectValue(allocator, context, "/repo", true)) |_| {} else |err| try expectRuntimeOom(err);
        if (zlsStatusResourceValue(allocator, context)) |_| {} else |err| try expectRuntimeOom(err);
        if (metricsResourceValue(allocator, context)) |_| {} else |err| try expectRuntimeOom(err);
        if (jobsResourceValue(allocator, context)) |_| {} else |err| try expectRuntimeOom(err);
        if (runEventsResourceValue(allocator, context)) |_| {} else |err| try expectRuntimeOom(err);
        if (workspaceRootsResourceValue(allocator, context)) |_| {} else |err| try expectRuntimeOom(err);
        if (dynamicResourceValue(allocator, context, "zigar://file/src/main.zig/imports")) |_| {} else |err| try expectRuntimeOom(err);
        if (resourceQueryValue(allocator, context, .{ .uri = "zigar://file/src/main.zig/symbols" })) |_| {} else |err| try expectRuntimeOom(err);
    }

    var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var session = test_fakes.FakeRuntimeSession{};
    defer session.deinit(std.testing.allocator);
    var catalog = NonOwningCatalog{ .text_value = "catalog" };
    const context = runtimeUxTestContext(&commands, &workspace, &scanner, &session, catalog.port());
    try std.testing.expectError(error.InvalidArguments, resourceQueryValue(std.testing.allocator, context, .{ .uri = "zigar://unknown" }));
}

test "runtime UX remaining builders cover late allocation cleanup" {
    const source =
        \\const std = @import("std");
        \\pub fn main() void {}
    ;

    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            if (astDeclSummaryJson(failing.allocator(), "src/main.zig", source)) |_| {} else |err| try expectRuntimeOom(err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            if (astImportsJson(failing.allocator(), "src/main.zig", source)) |_| {} else |err| try expectRuntimeOom(err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
            defer commands.deinit();
            var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner.deinit();
            var session = test_fakes.FakeRuntimeSession{};
            defer session.deinit(std.testing.allocator);
            var catalog = NonOwningCatalog{ .text_value = "catalog" };
            const context = runtimeUxTestContext(&commands, &workspace, &scanner, &session, catalog.port());
            try expectRuntimeWorkspaceMapExists(&workspace);
            if (rootsSyncValue(failing.allocator(), context, "file:///repo\n/tmp/alt", false)) |_| {} else |err| try expectRuntimeOom(err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
            defer commands.deinit();
            var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner.deinit();
            var session = test_fakes.FakeRuntimeSession{};
            defer session.deinit(std.testing.allocator);
            var catalog = NonOwningCatalog{ .text_value = "catalog" };
            const context = runtimeUxTestContext(&commands, &workspace, &scanner, &session, catalog.port());
            try seedRuntimeJob(&session);
            if (jobsResourceValue(failing.allocator(), context)) |_| {} else |err| try expectRuntimeOom(err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
            defer commands.deinit();
            var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner.deinit();
            var session = test_fakes.FakeRuntimeSession{};
            defer session.deinit(std.testing.allocator);
            var catalog = NonOwningCatalog{ .text_value = "catalog" };
            const context = runtimeUxTestContext(&commands, &workspace, &scanner, &session, catalog.port());
            try seedRuntimeJob(&session);
            if (runEventsResourceValue(failing.allocator(), context)) |_| {} else |err| try expectRuntimeOom(err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
            defer commands.deinit();
            var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner.deinit();
            var session = test_fakes.FakeRuntimeSession{};
            defer session.deinit(std.testing.allocator);
            var catalog = NonOwningCatalog{ .text_value = "catalog" };
            const context = runtimeUxTestContext(&commands, &workspace, &scanner, &session, catalog.port());
            if (workspaceRootsResourceValue(failing.allocator(), context)) |_| {} else |err| try expectRuntimeOom(err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
            defer commands.deinit();
            var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner.deinit();
            var session = test_fakes.FakeRuntimeSession{};
            defer session.deinit(std.testing.allocator);
            var catalog = NonOwningCatalog{ .text_value = "catalog" };
            const context = runtimeUxTestContext(&commands, &workspace, &scanner, &session, catalog.port());
            try workspace.expectRead(.{ .path = "src/main.zig", .max_bytes = max_resource_read, .provenance = "runtime_ux.dynamic_resource" }, source);
            if (dynamicResourceValue(failing.allocator(), context, "zigar://file/src/main.zig/imports")) |_| {} else |err| try expectRuntimeOom(err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
            defer commands.deinit();
            var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner.deinit();
            var session = test_fakes.FakeRuntimeSession{};
            defer session.deinit(std.testing.allocator);
            var catalog = NonOwningCatalog{ .text_value = "catalog" };
            const context = runtimeUxTestContext(&commands, &workspace, &scanner, &session, catalog.port());
            try workspace.expectRead(.{ .path = "src/main.zig", .max_bytes = max_resource_read, .provenance = "runtime_ux.dynamic_resource" }, source);
            if (resourceQueryValue(failing.allocator(), context, .{ .uri = "zigar://file/src/main.zig/symbols" })) |_| {} else |err| try expectRuntimeOom(err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
            defer commands.deinit();
            var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner.deinit();
            var session = test_fakes.FakeRuntimeSession{};
            defer session.deinit(std.testing.allocator);
            var catalog = NonOwningCatalog{ .text_value = "catalog" };
            const context = runtimeUxTestContext(&commands, &workspace, &scanner, &session, catalog.port());
            try expectRuntimeWorkspaceMapExists(&workspace);
            if (workspaceMapResultValue(failing.allocator(), context, "zigar_workspace_map", null)) |_| {} else |err| try expectRuntimeOom(err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
            defer commands.deinit();
            var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner.deinit();
            var session = test_fakes.FakeRuntimeSession{};
            defer session.deinit(std.testing.allocator);
            var catalog = NonOwningCatalog{ .text_value = "catalog" };
            const context = runtimeUxTestContext(&commands, &workspace, &scanner, &session, catalog.port());
            try seedRuntimeJob(&session);
            if (resourceQueryValue(failing.allocator(), context, .{ .uri = "zigar://jobs", .limit = 1 })) |_| {} else |err| try expectRuntimeOom(err);
        }
        {
            var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer backing.deinit();
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
            var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
            defer commands.deinit();
            var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
            defer workspace.deinit();
            var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
            defer scanner.deinit();
            var session = test_fakes.FakeRuntimeSession{};
            defer session.deinit(std.testing.allocator);
            var catalog = NonOwningCatalog{ .text_value = "catalog" };
            const context = runtimeUxTestContext(&commands, &workspace, &scanner, &session, catalog.port());
            if (resourceSubscribeValue(failing.allocator(), context, "zigar://jobs")) |_| {} else |err| try expectRuntimeOom(err);
        }
    }
}

fn expectRuntimeOom(err: anyerror) !void {
    try std.testing.expectEqual(error.OutOfMemory, err);
}
