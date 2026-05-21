const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const common = @import("common.zig");
const agent_values = @import("agent_values.zig");

const App = common.App;
const analysis = zigar.analysis;
const command = zigar.command;
const command_output = zigar.command_output;
const json_result = zigar.json_result;
const runtime_ux = zigar.runtime_ux;

const argBool = common.argBool;
const argInt = common.argInt;
const argString = common.argString;
const invalidArgumentResult = common.invalidArgumentResult;
const missingArgumentResult = common.missingArgumentResult;
const structured = common.structured;
const toolErrorFromError = common.toolErrorFromError;
const toolTimeout = common.toolTimeout;
const workspacePathErrorResult = common.workspacePathErrorResult;

const max_resource_read = 1024 * 1024;

pub fn zigarJobStart(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runJobTool(a, allocator, args, "zigar_job_start", false);
}

pub fn zigarRunStream(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return runJobTool(a, allocator, args, "zigar_run_stream", true);
}

pub fn zigarJobStatus(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const job_id = argString(args, "job_id") orelse return missingArgumentResult(allocator, "zigar_job_status", "job_id", "job id returned by zigar_job_start or zigar_run_stream");
    const job = a.runtime_ux.jobById(job_id) orelse return jobNotFound(allocator, "zigar_job_status", job_id);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_job_status" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "job", try jobValue(allocator, job));
    try obj.put(allocator, "result_available", .{ .bool = job.status.terminal() });
    try obj.put(allocator, "events_cursor", .{ .string = try cursorString(allocator, a.runtime_ux.event_count) });
    try obj.put(allocator, "limitations", try runtimeLimitationsValue(allocator));
    return structured(allocator, .{ .object = obj });
}

pub fn zigarJobResult(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const job_id = argString(args, "job_id") orelse return missingArgumentResult(allocator, "zigar_job_result", "job_id", "job id returned by zigar_job_start or zigar_run_stream");
    const job = a.runtime_ux.jobById(job_id) orelse return jobNotFound(allocator, "zigar_job_result", job_id);
    const cursor = parseCursor(argString(args, "cursor"));
    const limit = clampLimit(argInt(args, "limit", 25), 1, 100);
    const mode = argString(args, "mode") orelse "standard";

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_job_result" });
    try obj.put(allocator, "ok", .{ .bool = job.ok });
    try obj.put(allocator, "job", try jobValue(allocator, job));
    try obj.put(allocator, "stdout_tail", .{ .string = job.stdout_tail.slice() });
    try obj.put(allocator, "stderr_tail", .{ .string = job.stderr_tail.slice() });
    try obj.put(allocator, "stdout_truncated", .{ .bool = job.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = job.stderr_truncated });
    try obj.put(allocator, "events", try eventsPageValue(allocator, a, job.id.slice(), cursor, limit));
    try obj.put(allocator, "omitted_sections", try omittedSectionsValue(allocator, mode, &.{ "full_stdout", "full_stderr", "live_process_handle" }));
    try obj.put(allocator, "limitations", try runtimeLimitationsValue(allocator));
    return structured(allocator, .{ .object = obj });
}

pub fn zigarJobCancel(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const job_id = argString(args, "job_id") orelse return missingArgumentResult(allocator, "zigar_job_cancel", "job_id", "job id returned by zigar_job_start or zigar_run_stream");
    const reason = argString(args, "reason") orelse "client requested cancellation";
    const before = if (a.runtime_ux.jobById(job_id)) |job| job.status else return jobNotFound(allocator, "zigar_job_cancel", job_id);
    const job = a.runtime_ux.cancelJob(job_id, reason).?;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_job_cancel" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "cancelled", .{ .bool = !before.terminal() });
    try obj.put(allocator, "status", .{ .string = job.status.text() });
    try obj.put(allocator, "job", try jobValue(allocator, job));
    try obj.put(allocator, "note", .{ .string = if (before.terminal()) "job was already terminal; cancellation was recorded for auditability" else "job marked cancelled in process-local state" });
    try obj.put(allocator, "limitations", try runtimeLimitationsValue(allocator));
    return structured(allocator, .{ .object = obj });
}

pub fn zigarCancelStatus(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    var jobs = std.json.Array.init(allocator);
    if (argString(args, "job_id")) |job_id| {
        const job = a.runtime_ux.jobById(job_id) orelse return jobNotFound(allocator, "zigar_cancel_status", job_id);
        try jobs.append(try cancellationValue(allocator, job));
    } else {
        for (a.runtime_ux.jobs[0..a.runtime_ux.job_count]) |*job| try jobs.append(try cancellationValue(allocator, job));
    }

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_cancel_status" });
    try obj.put(allocator, "jobs", .{ .array = jobs });
    try obj.put(allocator, "job_count", .{ .integer = @intCast(jobs.items.len) });
    return structured(allocator, .{ .object = obj });
}

pub fn zigarRunEvents(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const cursor = parseCursor(argString(args, "cursor"));
    const limit = clampLimit(argInt(args, "limit", 50), 1, 200);
    const job_id = argString(args, "job_id");
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_run_events" });
    if (job_id) |id| try obj.put(allocator, "job_id", .{ .string = id }) else try obj.put(allocator, "job_id", .null);
    try obj.put(allocator, "events", try eventsPageValue(allocator, a, job_id, cursor, limit));
    return structured(allocator, .{ .object = obj });
}

pub fn zigarResourceQuery(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const uri = argString(args, "uri") orelse return missingArgumentResult(allocator, "zigar_resource_query", "uri", "zigar resource URI");
    const cursor = parseCursor(argString(args, "cursor"));
    const limit = clampLimit(argInt(args, "limit", 50), 1, 200);
    const mode = argString(args, "mode") orelse "standard";

    if (std.mem.startsWith(u8, uri, "zigar://file/")) {
        return fileResourceQuery(a, allocator, uri, mode);
    }
    if (std.mem.eql(u8, uri, "zigar://jobs")) {
        return structured(allocator, try jobsResourceValue(allocator, a, cursor, limit, mode));
    }
    if (std.mem.eql(u8, uri, "zigar://run/events")) {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "kind", .{ .string = "zigar_resource_query" });
        try obj.put(allocator, "uri", .{ .string = uri });
        try obj.put(allocator, "resource", try eventsPageValue(allocator, a, null, cursor, limit));
        return structured(allocator, .{ .object = obj });
    }
    if (std.mem.eql(u8, uri, "zigar://workspace/roots")) {
        return workspaceMapResult(a, allocator, "zigar_resource_query", uri);
    }
    if (std.mem.eql(u8, uri, "zigar://prompts")) {
        return structured(allocator, try promptPackValue(allocator, null, mode));
    }
    return invalidArgumentResult(allocator, "zigar_resource_query", "uri", "registered zigar URI or zigar://file/{path}/{symbols|diagnostics|imports}", uri, "Use resources/list, resources/templates/list, or zigar_workspace_map to discover supported URIs.");
}

pub fn zigarResourceSubscribe(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const uri = argString(args, "uri") orelse return missingArgumentResult(allocator, "zigar_resource_subscribe", "uri", "zigar resource URI");
    const sub = a.runtime_ux.subscribe(uri);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_resource_subscribe" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "subscription", try subscriptionValue(allocator, sub));
    try obj.put(allocator, "notification_method", .{ .string = "notifications/resources/updated" });
    try obj.put(allocator, "scope", .{ .string = "process_local" });
    return structured(allocator, .{ .object = obj });
}

pub fn zigarResourceUnsubscribe(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const subscription_id = argString(args, "subscription_id");
    const uri = argString(args, "uri");
    if (subscription_id == null and uri == null) return missingArgumentResult(allocator, "zigar_resource_unsubscribe", "subscription_id", "subscription id or uri");
    const id = subscription_id orelse "";
    const sub = a.runtime_ux.unsubscribe(id, uri) orelse return invalidArgumentResult(allocator, "zigar_resource_unsubscribe", "subscription_id", "active subscription id or uri", id, "Call zigar_resource_subscribe first, or pass a retained active subscription id.");
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_resource_unsubscribe" });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "subscription", try subscriptionValue(allocator, sub));
    return structured(allocator, .{ .object = obj });
}

pub fn zigarRootsSync(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    a.runtime_ux.ensureDefaultRoot(a.workspace.root);
    const roots = argString(args, "roots") orelse a.workspace.root;
    const apply = argBool(args, "apply", false);
    const before = a.runtime_ux.root_count;
    const preview = try rootsPreviewValue(allocator, roots, a.workspace.root);
    if (apply) a.runtime_ux.syncRoots(a.workspace.root, roots, true);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_roots_sync" });
    try obj.put(allocator, "apply", .{ .bool = apply });
    try obj.put(allocator, "changed", .{ .bool = apply and before != a.runtime_ux.root_count });
    try obj.put(allocator, "preview_roots", preview);
    try obj.put(allocator, "workspace", try workspaceMapValue(allocator, a));
    try obj.put(allocator, "note", .{ .string = "workspace roots are process-local guidance; file tools continue enforcing the configured zigar workspace path policy" });
    return structured(allocator, .{ .object = obj });
}

pub fn zigarWorkspaceMap(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return workspaceMapResult(a, allocator, "zigar_workspace_map", null);
}

pub fn zigarWorkspaceSelect(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    a.runtime_ux.ensureDefaultRoot(a.workspace.root);
    const workspace_id = argString(args, "workspace_id") orelse return missingArgumentResult(allocator, "zigar_workspace_select", "workspace_id", "root id or path from zigar_workspace_map");
    const apply = argBool(args, "apply", false);
    const root = a.runtime_ux.selectRoot(workspace_id, apply) orelse return invalidArgumentResult(allocator, "zigar_workspace_select", "workspace_id", "known workspace root id or path", workspace_id, "Call zigar_workspace_map and pass one of the returned root ids.");
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_workspace_select" });
    try obj.put(allocator, "apply", .{ .bool = apply });
    try obj.put(allocator, "selected", try rootValue(allocator, root));
    try obj.put(allocator, "workspace", try workspaceMapValue(allocator, a));
    try obj.put(allocator, "note", .{ .string = "selection is process-local guidance; file access remains constrained to the configured zigar workspace" });
    return structured(allocator, .{ .object = obj });
}

pub fn zigarAgentGuideV2(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const client = argString(args, "client") orelse "generic";
    const task = argString(args, "task") orelse "zig development";
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
    try obj.put(allocator, "workflow_contract", try agent_values.workflowContractValue(allocator, "workspace/tool/profile/runtime discovery", "deterministic tool sequence guidance", "medium", "guidance is not evidence that commands passed", "collect job or tool evidence before reporting success", "stop when requested evidence exists or a structured tool_error blocks progress", &.{ "zigar_job_result", "zigar_run_events" }));
    return structured(allocator, .{ .object = obj });
}

pub fn zigarClientGuide(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const client = argString(args, "client") orelse "generic";
    const task = argString(args, "task") orelse "mcp integration";
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
    return structured(allocator, .{ .object = obj });
}

pub fn zigarPromptPack(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    const workflow = argString(args, "workflow");
    return structured(allocator, try promptPackValue(allocator, workflow, "standard"));
}

fn runJobTool(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, include_events: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    a.runtime_ux.ensureDefaultRoot(a.workspace.root);
    const command_name = argString(args, "command") orelse return missingArgumentResult(allocator, tool_name, "command", "one of build, build-test, test, check, fmt-check");
    const timeout_ms = toolTimeout(a, args);
    const planned = buildRunPlan(a, allocator, args, tool_name, command_name) catch |err| switch (err) {
        error.InvalidArguments => return invalidArgumentResult(allocator, tool_name, "command", "one of build, build-test, test, check, fmt-check", command_name, "Choose an allow-listed command; zigar does not accept arbitrary shell commands here."),
        error.MissingFile => return missingArgumentResult(allocator, tool_name, "file", "workspace-relative Zig file for test, check, or fmt-check"),
        error.PathOutsideWorkspace, error.EmptyPath => return workspacePathErrorResult(a, allocator, tool_name, argString(args, "file") orelse "", err),
        error.OutOfMemory => return error.OutOfMemory,
        error.Timeout => return error.Timeout,
        error.PermissionDenied => return error.PermissionDenied,
        error.Unknown => return error.Unknown,
        error.ExecutionFailed => return error.ExecutionFailed,
        error.ResourceNotFound => return error.ResourceNotFound,
    };

    var title_buf: [160]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s} {s}", .{ tool_name, command_name }) catch tool_name;
    const job = a.runtime_ux.startJob(title, planned.command_text, timeout_ms);
    a.command_calls += 1;
    const result = command.run(allocator, a.io, a.workspace.root, planned.argv, timeout_ms) catch |err| {
        a.tool_errors += 1;
        a.observability.recordCommand(title, planned.argv, 0, false, @errorName(err));
        a.runtime_ux.failJob(job, @errorName(err), 0);
        return commandErrorJobResult(a, allocator, tool_name, job, planned.argv, timeout_ms, err, include_events);
    };
    defer result.deinit(allocator);
    a.observability.recordCommand(title, planned.argv, result.duration_ms, result.succeeded(), null);
    const stdout = command_output.safeTextAlloc(allocator, result.stdout) catch return error.OutOfMemory;
    const stderr = command_output.safeTextAlloc(allocator, result.stderr) catch return error.OutOfMemory;
    a.runtime_ux.finishJob(job, if (result.succeeded()) .completed else .failed, result.succeeded(), result.duration_ms, command.termText(result.term), exitCode(result.term), stdout.text, stderr.text, result.stdout_truncated, result.stderr_truncated);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "ok", .{ .bool = result.succeeded() });
    try obj.put(allocator, "job_id", .{ .string = job.id.slice() });
    try obj.put(allocator, "status", .{ .string = job.status.text() });
    try obj.put(allocator, "job", try jobValue(allocator, job));
    try obj.put(allocator, "cwd", .{ .string = a.workspace.root });
    try obj.put(allocator, "argv", try common.argvValue(allocator, planned.argv));
    try obj.put(allocator, "result_available", .{ .bool = true });
    try obj.put(allocator, "stdout_tail", .{ .string = job.stdout_tail.slice() });
    try obj.put(allocator, "stderr_tail", .{ .string = job.stderr_tail.slice() });
    try obj.put(allocator, "stdout_truncated", .{ .bool = job.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = job.stderr_truncated });
    if (include_events) try obj.put(allocator, "events", try eventsPageValue(allocator, a, job.id.slice(), 0, 50));
    try obj.put(allocator, "next_tools", try stringArrayValue(allocator, &.{ "zigar_job_status", "zigar_job_result", "zigar_run_events" }));
    try obj.put(allocator, "limitations", try runtimeLimitationsValue(allocator));
    return structured(allocator, .{ .object = obj });
}

const RunPlan = struct {
    argv: []const []const u8,
    command_text: []const u8,
};

fn buildRunPlan(a: *App, allocator: std.mem.Allocator, args: ?std.json.Value, tool_name: []const u8, command_name: []const u8) !RunPlan {
    const extra = common.splitToolArgs(allocator, argString(args, "args")) catch |err| switch (err) {
        error.InvalidArguments => return error.InvalidArguments,
        error.OutOfMemory => return error.OutOfMemory,
        else => return err,
    };
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    try argv.append(allocator, a.config.zig_path);
    if (std.mem.eql(u8, command_name, "build")) {
        try argv.append(allocator, "build");
    } else if (std.mem.eql(u8, command_name, "build-test")) {
        try argv.append(allocator, "build");
        try argv.append(allocator, "test");
    } else if (std.mem.eql(u8, command_name, "test")) {
        const file = argString(args, "file") orelse return error.MissingFile;
        const rel = try checkedRelativePath(a, allocator, tool_name, file);
        try argv.append(allocator, "test");
        try argv.append(allocator, rel);
    } else if (std.mem.eql(u8, command_name, "check")) {
        const file = argString(args, "file") orelse return error.MissingFile;
        const rel = try checkedRelativePath(a, allocator, tool_name, file);
        try argv.append(allocator, "ast-check");
        try argv.append(allocator, rel);
    } else if (std.mem.eql(u8, command_name, "fmt-check")) {
        const file = argString(args, "file") orelse return error.MissingFile;
        const rel = try checkedRelativePath(a, allocator, tool_name, file);
        try argv.append(allocator, "fmt");
        try argv.append(allocator, "--check");
        try argv.append(allocator, rel);
    } else {
        return error.InvalidArguments;
    }
    try argv.appendSlice(allocator, extra);
    const owned_argv = try argv.toOwnedSlice(allocator);
    return .{ .argv = owned_argv, .command_text = try common.commandString(allocator, owned_argv) };
}

fn checkedRelativePath(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, path: []const u8) ![]const u8 {
    _ = tool_name;
    const resolved = try a.workspace.resolve(path);
    defer a.workspace.allocator.free(resolved);
    return allocator.dupe(u8, a.workspace.relative(resolved));
}

fn commandErrorJobResult(a: *App, allocator: std.mem.Allocator, tool_name: []const u8, job: *const runtime_ux.JobRecord, argv: []const []const u8, timeout_ms: i64, err: anyerror, include_events: bool) mcp.tools.ToolError!mcp.tools.ToolResult {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = tool_name });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "job_id", .{ .string = job.id.slice() });
    try obj.put(allocator, "status", .{ .string = job.status.text() });
    try obj.put(allocator, "job", try jobValue(allocator, job));
    try obj.put(allocator, "argv", try common.argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "error", .{ .string = @errorName(err) });
    try obj.put(allocator, "error_kind", .{ .string = command.errorKind(err) });
    if (include_events) try obj.put(allocator, "events", try eventsPageValue(allocator, a, job.id.slice(), 0, 50));
    try obj.put(allocator, "limitations", try runtimeLimitationsValue(allocator));
    return structured(allocator, .{ .object = obj });
}

fn fileResourceQuery(a: *App, allocator: std.mem.Allocator, uri: []const u8, mode: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    const prefix = "zigar://file/";
    const rest = uri[prefix.len..];
    const slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse return invalidArgumentResult(allocator, "zigar_resource_query", "uri", "zigar://file/{path}/{symbols|diagnostics|imports}", uri, "Include a file path and one resource kind suffix.");
    const path = rest[0..slash];
    const kind = rest[slash + 1 ..];
    if (path.len == 0) return invalidArgumentResult(allocator, "zigar_resource_query", "uri", "non-empty workspace file URI", uri, "Pass a workspace-relative Zig file path.");
    const resolved = a.workspace.resolve(path) catch |err| return workspacePathErrorResult(a, allocator, "zigar_resource_query", path, err);
    defer a.workspace.allocator.free(resolved);
    const rel = a.workspace.relative(resolved);
    const bytes = std.Io.Dir.cwd().readFileAlloc(a.io, resolved, allocator, .limited(max_resource_read)) catch |err| return toolErrorFromError(allocator, .{
        .tool = "zigar_resource_query",
        .operation = "read_dynamic_file_resource",
        .phase = "workspace_read",
        .code = "resource_file_read_failed",
        .category = "filesystem",
        .resolution = "Confirm the file exists inside the configured zigar workspace and retry.",
        .details = &.{.{ .key = "uri", .value = .{ .string = uri } }},
    }, err);
    defer allocator.free(bytes);

    const resource_value = if (std.mem.eql(u8, kind, "symbols"))
        analysis.astDeclSummaryJson(allocator, rel, bytes) catch |err| return analysisResourceError(allocator, uri, "symbols", err)
    else if (std.mem.eql(u8, kind, "imports"))
        analysis.astImportsJson(allocator, rel, bytes) catch |err| return analysisResourceError(allocator, uri, "imports", err)
    else if (std.mem.eql(u8, kind, "diagnostics"))
        try diagnosticsResourceValue(allocator, rel)
    else
        return invalidArgumentResult(allocator, "zigar_resource_query", "uri", "resource kind suffix symbols, diagnostics, or imports", uri, "Use one of the registered zigar://file resource template suffixes.");

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_resource_query" });
    try obj.put(allocator, "uri", .{ .string = uri });
    try obj.put(allocator, "resource_kind", .{ .string = kind });
    try obj.put(allocator, "path", .{ .string = rel });
    try obj.put(allocator, "resource", resource_value);
    try obj.put(allocator, "omitted_sections", try omittedSectionsValue(allocator, mode, &.{"full_file_text"}));
    return structured(allocator, .{ .object = obj });
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

fn workspaceMapResult(a: *App, allocator: std.mem.Allocator, kind: []const u8, uri: ?[]const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    a.runtime_ux.ensureDefaultRoot(a.workspace.root);
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = kind });
    if (uri) |u| try obj.put(allocator, "uri", .{ .string = u });
    try obj.put(allocator, "workspace", try workspaceMapValue(allocator, a));
    return structured(allocator, .{ .object = obj });
}

fn workspaceMapValue(allocator: std.mem.Allocator, a: *App) !std.json.Value {
    var roots = std.json.Array.init(allocator);
    for (a.runtime_ux.roots[0..a.runtime_ux.root_count]) |*root| try roots.append(try rootValue(allocator, root));
    var entry_points = std.json.Array.init(allocator);
    if (workspacePathExists(a, "build.zig")) try entry_points.append(.{ .string = "build.zig" });
    if (workspacePathExists(a, "build.zig.zon")) try entry_points.append(.{ .string = "build.zig.zon" });
    if (workspacePathExists(a, "src")) try entry_points.append(.{ .string = "src" });
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "configured_root", .{ .string = a.workspace.root });
    try obj.put(allocator, "cache_root", .{ .string = a.workspace.cache_root });
    try obj.put(allocator, "roots", .{ .array = roots });
    try obj.put(allocator, "root_count", .{ .integer = @intCast(a.runtime_ux.root_count) });
    try obj.put(allocator, "selected_root_id", .{ .string = a.runtime_ux.roots[a.runtime_ux.selected_root].id.slice() });
    try obj.put(allocator, "entry_points", .{ .array = entry_points });
    try obj.put(allocator, "path_safety", .{ .string = "all file tools resolve paths inside configured_root" });
    return .{ .object = obj };
}

fn jobsResourceValue(allocator: std.mem.Allocator, a: *App, cursor: u64, limit: usize, mode: []const u8) !std.json.Value {
    var page = std.json.Array.init(allocator);
    const start: usize = @intCast(@min(cursor, a.runtime_ux.job_count));
    const end = @min(a.runtime_ux.job_count, start + limit);
    for (a.runtime_ux.jobs[start..end]) |*job| try page.append(try jobValue(allocator, job));
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_resource_query" });
    try obj.put(allocator, "uri", .{ .string = "zigar://jobs" });
    try obj.put(allocator, "jobs", .{ .array = page });
    try obj.put(allocator, "job_count", .{ .integer = @intCast(a.runtime_ux.job_count) });
    if (end < a.runtime_ux.job_count) try obj.put(allocator, "nextCursor", .{ .string = try cursorString(allocator, end) });
    try obj.put(allocator, "omitted_sections", try omittedSectionsValue(allocator, mode, &.{ "full_stdout", "full_stderr" }));
    return .{ .object = obj };
}

fn jobValue(allocator: std.mem.Allocator, job: *const runtime_ux.JobRecord) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "job_id", .{ .string = job.id.slice() });
    try obj.put(allocator, "label", .{ .string = job.label.slice() });
    try obj.put(allocator, "command", .{ .string = job.command.slice() });
    try obj.put(allocator, "status", .{ .string = job.status.text() });
    try obj.put(allocator, "ok", .{ .bool = job.ok });
    try obj.put(allocator, "created_sequence", .{ .integer = @intCast(job.created_sequence) });
    try obj.put(allocator, "updated_sequence", .{ .integer = @intCast(job.updated_sequence) });
    try obj.put(allocator, "duration_ms", .{ .integer = job.duration_ms });
    try obj.put(allocator, "timeout_ms", .{ .integer = job.timeout_ms });
    try obj.put(allocator, "term", .{ .string = job.term.slice() });
    if (job.exit_code) |code| try obj.put(allocator, "exit_code", .{ .integer = code }) else try obj.put(allocator, "exit_code", .null);
    try obj.put(allocator, "cancellation_requested", .{ .bool = job.cancellation_requested });
    try obj.put(allocator, "cancellation_reason", .{ .string = job.cancellation_reason.slice() });
    return .{ .object = obj };
}

fn cancellationValue(allocator: std.mem.Allocator, job: *const runtime_ux.JobRecord) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "job_id", .{ .string = job.id.slice() });
    try obj.put(allocator, "status", .{ .string = job.status.text() });
    try obj.put(allocator, "terminal", .{ .bool = job.status.terminal() });
    try obj.put(allocator, "cancellation_requested", .{ .bool = job.cancellation_requested });
    try obj.put(allocator, "cancellation_reason", .{ .string = job.cancellation_reason.slice() });
    return .{ .object = obj };
}

fn eventsPageValue(allocator: std.mem.Allocator, a: *App, job_filter: ?[]const u8, cursor: u64, limit: usize) !std.json.Value {
    const first_available: u64 = if (a.runtime_ux.event_count > runtime_ux.max_events) a.runtime_ux.event_count - runtime_ux.max_events + 1 else 1;
    var sequence = @max(cursor + 1, first_available);
    var events = std.json.Array.init(allocator);
    var appended: usize = 0;
    while (sequence <= a.runtime_ux.event_count and appended < limit) : (sequence += 1) {
        const event = &a.runtime_ux.events[runtime_ux.ringIndex(sequence, runtime_ux.max_events)];
        if (job_filter) |filter| {
            if (!std.mem.eql(u8, event.job_id.slice(), filter)) continue;
        }
        try events.append(try eventValue(allocator, event));
        appended += 1;
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "items", .{ .array = events });
    try obj.put(allocator, "cursor", .{ .string = try cursorString(allocator, cursor) });
    if (sequence <= a.runtime_ux.event_count) try obj.put(allocator, "nextCursor", .{ .string = try cursorString(allocator, sequence - 1) });
    try obj.put(allocator, "event_count", .{ .integer = @intCast(a.runtime_ux.event_count) });
    try obj.put(allocator, "retention", .{ .string = "bounded_ring" });
    return .{ .object = obj };
}

fn eventValue(allocator: std.mem.Allocator, event: *const runtime_ux.EventRecord) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "sequence", .{ .integer = @intCast(event.sequence) });
    try obj.put(allocator, "job_id", .{ .string = event.job_id.slice() });
    try obj.put(allocator, "event", .{ .string = event.event.slice() });
    try obj.put(allocator, "stream", .{ .string = event.stream.slice() });
    try obj.put(allocator, "message", .{ .string = event.message.slice() });
    try obj.put(allocator, "text", .{ .string = event.text.slice() });
    try obj.put(allocator, "elapsed_ms", .{ .integer = event.elapsed_ms });
    return .{ .object = obj };
}

fn rootValue(allocator: std.mem.Allocator, root: *const runtime_ux.WorkspaceRoot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "id", .{ .string = root.id.slice() });
    try obj.put(allocator, "path", .{ .string = root.path.slice() });
    try obj.put(allocator, "uri", .{ .string = root.uri.slice() });
    try obj.put(allocator, "name", .{ .string = root.name.slice() });
    try obj.put(allocator, "selected", .{ .bool = root.selected });
    return .{ .object = obj };
}

fn subscriptionValue(allocator: std.mem.Allocator, sub: *const runtime_ux.Subscription) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "subscription_id", .{ .string = sub.id.slice() });
    try obj.put(allocator, "uri", .{ .string = sub.uri.slice() });
    try obj.put(allocator, "active", .{ .bool = sub.active });
    try obj.put(allocator, "created_sequence", .{ .integer = @intCast(sub.created_sequence) });
    return .{ .object = obj };
}

fn rootsPreviewValue(allocator: std.mem.Allocator, roots_text: []const u8, default_root: []const u8) !std.json.Value {
    var roots = std.json.Array.init(allocator);
    var count: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, roots_text, "\n\r\t ");
    while (tokens.next()) |token| {
        if (count >= runtime_ux.max_roots) break;
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

fn promptPackValue(allocator: std.mem.Allocator, workflow: ?[]const u8, mode: []const u8) !std.json.Value {
    var workflows = std.json.Array.init(allocator);
    for (workflow_defs) |def| {
        if (workflow) |wanted| {
            if (!std.mem.eql(u8, wanted, def.name)) continue;
        }
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

fn runtimeLimitationsValue(allocator: std.mem.Allocator) !std.json.Value {
    return stringArrayValue(allocator, &.{
        "job and event state is process-local and not persisted across server restarts",
        "allow-listed run tools execute synchronously before returning a retained job result",
        "cancellation records intent for retained jobs but cannot kill a command that has already completed",
        "stdout and stderr are stored as bounded tails",
    });
}

fn omittedSectionsValue(allocator: std.mem.Allocator, mode: []const u8, sections: []const []const u8) !std.json.Value {
    var arr = std.json.Array.init(allocator);
    if (std.mem.eql(u8, mode, "deep")) return .{ .array = arr };
    for (sections) |section| try arr.append(.{ .string = section });
    return .{ .array = arr };
}

fn stringArrayValue(allocator: std.mem.Allocator, values: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

fn workspacePathExists(a: *App, path: []const u8) bool {
    const resolved = a.workspace.resolve(path) catch return false;
    defer a.workspace.allocator.free(resolved);
    var dir = std.Io.Dir.openDirAbsolute(a.io, resolved, .{}) catch {
        var file = std.Io.Dir.cwd().openFile(a.io, resolved, .{}) catch return false;
        file.close(a.io);
        return true;
    };
    dir.close(a.io);
    return true;
}

fn exitCode(term: std.process.Child.Term) ?i64 {
    return switch (term) {
        .exited => |code| @intCast(code),
        else => null,
    };
}

fn parseCursor(cursor: ?[]const u8) u64 {
    const text = cursor orelse return 0;
    return std.fmt.parseUnsigned(u64, text, 10) catch 0;
}

fn cursorString(allocator: std.mem.Allocator, cursor: anytype) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{cursor});
}

fn clampLimit(value: i64, min: usize, max: usize) usize {
    if (value < @as(i64, @intCast(min))) return min;
    if (value > @as(i64, @intCast(max))) return max;
    return @intCast(value);
}

fn jobNotFound(allocator: std.mem.Allocator, tool_name: []const u8, job_id: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return invalidArgumentResult(allocator, tool_name, "job_id", "retained zigar job id", job_id, "Use zigar_job_start, zigar_run_stream, zigar_run_events, or zigar://jobs to discover retained job ids.");
}

fn analysisResourceError(allocator: std.mem.Allocator, uri: []const u8, kind: []const u8, err: anyerror) mcp.tools.ToolError!mcp.tools.ToolResult {
    return toolErrorFromError(allocator, .{
        .tool = "zigar_resource_query",
        .operation = "read_dynamic_file_resource",
        .phase = "static_analysis",
        .code = "resource_analysis_failed",
        .category = "analysis",
        .resolution = "Confirm the Zig file parses, or use compiler/ZLS tools for diagnostics.",
        .details = &.{
            .{ .key = "uri", .value = .{ .string = uri } },
            .{ .key = "resource_kind", .value = .{ .string = kind } },
        },
    }, err);
}
