const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const catalog = zigar.catalog;
const json_result = zigar.json_result;
const resource_errors = zigar.resource_errors;
const runtime_ux = zigar.runtime_ux;
const common = @import("common.zig");

const App = common.App;
const metricsValue = common.metricsValue;
const zlsStatusValue = common.zlsStatusValue;
const responseResult = common.responseResult;

pub fn workspaceResource(a: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const body = std.fmt.allocPrint(allocator, "workspace={s}\ncache={s}\nzig={s}\nzwanzig={s}\nzflame={s}\ndiff_folded={s}\n", .{ a.workspace.root, a.workspace.cache_root, a.config.zig_path, a.config.zwanzig_path, a.config.zflame_path, a.config.diff_folded_path }) catch return error.OutOfMemory;
    return .{ .uri = uri, .mimeType = "text/plain", .text = body };
}

pub fn jsonResource(allocator: std.mem.Allocator, uri: []const u8, value: std.json.Value) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &aw.writer) catch |err| return resourceFailure(allocator, uri, .{
        .resource = "json_resource",
        .operation = "serialize_resource",
        .phase = "stringify_json",
        .code = "json_serialization_failed",
        .category = "serialization",
        .resolution = "Report this zigar bug with the resource URI and the operation that produced an unserializable JSON value.",
    }, err);
    return .{ .uri = uri, .mimeType = "application/json", .text = aw.toOwnedSlice() catch return error.OutOfMemory };
}

pub fn zlsStatusResource(a: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    var value = zlsStatusValue(allocator, a) catch |err| return resourceFailure(allocator, uri, .{
        .resource = "zls_status",
        .operation = "read_resource",
        .phase = "build_status",
        .code = "zls_status_failed",
        .category = "lsp",
        .resolution = "Run zigar_doctor with probe_backends=false and retry the resource read after checking the ZLS session state.",
    }, err);
    var obj = &value.object;
    if (a.zls_initialize_response) |response| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            const caps = if (responseResult(p.value)) |result| switch (result) {
                .object => |result_obj| result_obj.get("capabilities") orelse .null,
                else => .null,
            } else .null;
            var cap_json: std.ArrayList(u8) = .empty;
            errdefer cap_json.deinit(allocator);
            json_result.serializeValue(allocator, &cap_json, caps) catch |err| return resourceFailure(allocator, uri, .{
                .resource = "zls_status",
                .operation = "read_resource",
                .phase = "serialize_server_capabilities",
                .code = "zls_capabilities_serialization_failed",
                .category = "lsp",
                .resolution = "Retry after restarting the ZLS session; report this with zigar://zls/status output if it persists.",
            }, err);
            obj.put(allocator, "server_capabilities_json", .{ .string = cap_json.toOwnedSlice(allocator) catch return error.OutOfMemory }) catch return error.OutOfMemory;
        }
    }
    return jsonResource(allocator, uri, value);
}

pub fn capabilitiesResource(_: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return catalogResource(allocator, uri);
}

pub fn schemaResource(_: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return catalogResource(allocator, uri);
}

pub fn catalogResource(allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const body = catalog.text(allocator) catch |err| return resourceFailure(allocator, uri, .{
        .resource = "tool_catalog",
        .operation = "read_resource",
        .phase = "render_catalog",
        .code = "tool_catalog_render_failed",
        .category = "catalog",
        .resolution = "Run zig build docs-check json-check to verify the generated tool catalog, then retry the resource read.",
    }, err);
    return .{ .uri = uri, .mimeType = "application/json", .text = body };
}

pub fn importGraphResource(a: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const body = analysis.importGraph(allocator, a.io, a.workspace.root, 200) catch |err| return resourceFailure(allocator, uri, .{
        .resource = "workspace_import_graph",
        .operation = "read_resource",
        .phase = "scan_import_graph",
        .code = "import_graph_failed",
        .category = "analysis",
        .resolution = "Run zig_import_graph_json for structured diagnostics, check workspace readability, then retry zigar://workspace/import-graph.",
        .details = &.{.{ .key = "workspace", .value = .{ .string = a.workspace.root } }},
    }, err);
    return .{ .uri = uri, .mimeType = "text/plain", .text = body };
}

pub fn metricsResource(a: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const value = metricsValue(a, allocator) catch |err| return resourceFailure(allocator, uri, .{
        .resource = "metrics",
        .operation = "read_resource",
        .phase = "build_metrics",
        .code = "metrics_failed",
        .category = "runtime_state",
        .resolution = "Retry the resource read; report this with zigar_workspace_info if metrics cannot be produced.",
    }, err);
    return jsonResource(allocator, uri, value);
}

pub fn jobsResource(a: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    var jobs = std.json.Array.init(allocator);
    for (a.runtime_ux.jobs[0..a.runtime_ux.job_count]) |*job| try jobs.append(try jobResourceValue(allocator, job));
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_jobs_resource" });
    try obj.put(allocator, "jobs", .{ .array = jobs });
    try obj.put(allocator, "job_count", .{ .integer = @intCast(a.runtime_ux.job_count) });
    try obj.put(allocator, "retention", .{ .string = "process_local_bounded_ring" });
    return jsonResource(allocator, uri, .{ .object = obj });
}

pub fn runEventsResource(a: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    var events = std.json.Array.init(allocator);
    const first_available: u64 = if (a.runtime_ux.event_count > runtime_ux.max_events) a.runtime_ux.event_count - runtime_ux.max_events + 1 else 1;
    var sequence = first_available;
    while (sequence <= a.runtime_ux.event_count) : (sequence += 1) {
        try events.append(try eventResourceValue(allocator, &a.runtime_ux.events[runtime_ux.ringIndex(sequence, runtime_ux.max_events)]));
    }
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_run_events_resource" });
    try obj.put(allocator, "events", .{ .array = events });
    try obj.put(allocator, "event_count", .{ .integer = @intCast(a.runtime_ux.event_count) });
    try obj.put(allocator, "retention", .{ .string = "process_local_bounded_ring" });
    return jsonResource(allocator, uri, .{ .object = obj });
}

pub fn workspaceRootsResource(a: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    a.runtime_ux.ensureDefaultRoot(a.workspace.root);
    var roots = std.json.Array.init(allocator);
    for (a.runtime_ux.roots[0..a.runtime_ux.root_count]) |*root| try roots.append(try rootResourceValue(allocator, root));
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_workspace_roots_resource" });
    try obj.put(allocator, "configured_root", .{ .string = a.workspace.root });
    try obj.put(allocator, "roots", .{ .array = roots });
    try obj.put(allocator, "selected_root_id", .{ .string = a.runtime_ux.roots[a.runtime_ux.selected_root].id.slice() });
    try obj.put(allocator, "path_safety", .{ .string = "file tools resolve paths inside configured_root" });
    return jsonResource(allocator, uri, .{ .object = obj });
}

pub fn dynamicResource(a: *App, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    if (!std.mem.startsWith(u8, uri, "zigar://file/")) return error.NotFound;
    const value = dynamicFileResourceValue(a, allocator, uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUri => return resourceFailure(allocator, uri, dynamicResourceFailure("parse_dynamic_uri", "invalid_dynamic_resource_uri", "path_safety", "Use zigar://file/{path}/{symbols|diagnostics|imports} with a path inside the configured workspace."), err),
        error.PathOutsideWorkspace, error.EmptyPath, error.FileNotFound, error.AccessDenied, error.PermissionDenied => return resourceFailure(allocator, uri, dynamicResourceFailure("read_dynamic_file", "dynamic_resource_unavailable", "filesystem", "Confirm the file exists inside the configured workspace and retry the resource read."), err),
        else => return resourceFailure(allocator, uri, dynamicResourceFailure("build_dynamic_resource", "dynamic_resource_failed", "analysis", "Retry with zigar_resource_query for a structured tool_error and inspect the requested file."), err),
    };
    return jsonResource(allocator, uri, value);
}

pub fn profilePrompt(_: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const messages = allocator.alloc(mcp.prompts.PromptMessage, 1) catch return error.OutOfMemory;
    errdefer allocator.free(messages);
    const text = allocator.dupe(u8, "Use zigar_workspace_info, zig_profile_plan, zig_profile_run, zig_flamegraph, and zig_flamegraph_diff to build a deterministic Zig profiling workflow. Do not edit source files unless an explicit tool argument requires apply=true.") catch return error.OutOfMemory;
    messages[0] = mcp.prompts.userMessage(text);
    return messages;
}

pub fn workflowPrompt(_: *App, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const name = switch (args orelse .null) {
        .object => |obj| switch (obj.get("workflow") orelse .null) {
            .string => |s| s,
            else => "zigar_test_workflow",
        },
        else => "zigar_test_workflow",
    };
    const text = workflowPromptText(name);
    const messages = allocator.alloc(mcp.prompts.PromptMessage, 1) catch return error.OutOfMemory;
    errdefer allocator.free(messages);
    messages[0] = mcp.prompts.userMessage(allocator.dupe(u8, text) catch return error.OutOfMemory);
    return messages;
}

pub fn workflowPromptNamed(_: *App, allocator: std.mem.Allocator, name: []const u8) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const messages = allocator.alloc(mcp.prompts.PromptMessage, 1) catch return error.OutOfMemory;
    errdefer allocator.free(messages);
    messages[0] = mcp.prompts.userMessage(allocator.dupe(u8, workflowPromptText(name)) catch return error.OutOfMemory);
    return messages;
}

fn dynamicFileResourceValue(a: *App, allocator: std.mem.Allocator, uri: []const u8) !std.json.Value {
    const prefix = "zigar://file/";
    const rest = uri[prefix.len..];
    const slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse return error.InvalidUri;
    const path = rest[0..slash];
    const kind = rest[slash + 1 ..];
    if (path.len == 0) return error.InvalidUri;
    const resolved = try a.workspace.resolve(path);
    defer a.workspace.allocator.free(resolved);
    const rel = a.workspace.relative(resolved);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(a.io, resolved, allocator, .limited(common.source_read_limit));
    defer allocator.free(bytes);

    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_dynamic_file_resource" });
    try obj.put(allocator, "uri", .{ .string = uri });
    try obj.put(allocator, "path", .{ .string = rel });
    try obj.put(allocator, "resource_kind", .{ .string = kind });
    if (std.mem.eql(u8, kind, "symbols")) {
        try obj.put(allocator, "resource", try analysis.astDeclSummaryJson(allocator, rel, bytes));
    } else if (std.mem.eql(u8, kind, "imports")) {
        try obj.put(allocator, "resource", try analysis.astImportsJson(allocator, rel, bytes));
    } else if (std.mem.eql(u8, kind, "diagnostics")) {
        var diagnostics = std.json.ObjectMap.empty;
        try diagnostics.put(allocator, "kind", .{ .string = "zigar_file_diagnostics_resource" });
        try diagnostics.put(allocator, "file", .{ .string = rel });
        try diagnostics.put(allocator, "diagnostics", .{ .array = std.json.Array.init(allocator) });
        try diagnostics.put(allocator, "diagnostic_count", .{ .integer = 0 });
        try diagnostics.put(allocator, "source", .{ .string = "static_resource_query" });
        try diagnostics.put(allocator, "note", .{ .string = "read-only resource does not execute Zig or require ZLS; use zig_diagnostics_all or zig_check for authoritative diagnostics" });
        try obj.put(allocator, "resource", .{ .object = diagnostics });
    } else {
        return error.InvalidUri;
    }
    return .{ .object = obj };
}

fn jobResourceValue(allocator: std.mem.Allocator, job: *const runtime_ux.JobRecord) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "job_id", .{ .string = job.id.slice() });
    try obj.put(allocator, "label", .{ .string = job.label.slice() });
    try obj.put(allocator, "command", .{ .string = job.command.slice() });
    try obj.put(allocator, "status", .{ .string = job.status.text() });
    try obj.put(allocator, "ok", .{ .bool = job.ok });
    try obj.put(allocator, "duration_ms", .{ .integer = job.duration_ms });
    try obj.put(allocator, "stdout_tail", .{ .string = job.stdout_tail.slice() });
    try obj.put(allocator, "stderr_tail", .{ .string = job.stderr_tail.slice() });
    return .{ .object = obj };
}

fn eventResourceValue(allocator: std.mem.Allocator, event: *const runtime_ux.EventRecord) !std.json.Value {
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

fn rootResourceValue(allocator: std.mem.Allocator, root: *const runtime_ux.WorkspaceRoot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "id", .{ .string = root.id.slice() });
    try obj.put(allocator, "path", .{ .string = root.path.slice() });
    try obj.put(allocator, "uri", .{ .string = root.uri.slice() });
    try obj.put(allocator, "name", .{ .string = root.name.slice() });
    try obj.put(allocator, "selected", .{ .bool = root.selected });
    return .{ .object = obj };
}

pub fn workflowPromptText(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "zigar_compile_error_workflow")) return "Use zigar_run_stream or zig_check evidence, then zig_compile_error_index, zig_explain_errors, and zigar_failure_fusion before proposing the smallest fix.";
    if (std.mem.eql(u8, name, "zigar_refactor_workflow")) return "Use owner, symbol, import, impact, public API, and changed-file tools before editing; validate with format, check, tests, and patch guard evidence.";
    if (std.mem.eql(u8, name, "zigar_api_change_workflow")) return "Snapshot public API, compare API changes, inspect references and import edges, then validate with bounded build and test evidence.";
    if (std.mem.eql(u8, name, "zigar_release_workflow")) return "Check profile, toolchain, backend conformance, docs drift, release claims, JSON fixtures, smoke fixtures, and release-check evidence before reporting release readiness.";
    if (std.mem.eql(u8, name, "zigar_perf_workflow")) return "Use profiling plan, run, flamegraph, and flamegraph diff tools while keeping profiler backend availability explicit.";
    return "Discover relevant tests, run the narrowest bounded zigar job, triage failures, and broaden only after local evidence is clean.";
}

const ResourceFailureSpec = struct {
    resource: []const u8,
    operation: []const u8,
    phase: []const u8,
    code: []const u8,
    category: []const u8,
    retryable: bool = false,
    resolution: []const u8,
    details: []const resource_errors.Detail = &.{},
};

fn resourceFailure(allocator: std.mem.Allocator, uri: []const u8, spec: ResourceFailureSpec, err: anyerror) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return resource_errors.jsonContentFromError(allocator, .{
        .uri = uri,
        .resource = spec.resource,
        .operation = spec.operation,
        .phase = spec.phase,
        .code = spec.code,
        .category = spec.category,
        .retryable = spec.retryable,
        .resolution = spec.resolution,
        .details = spec.details,
    }, err);
}

fn dynamicResourceFailure(phase: []const u8, code: []const u8, category: []const u8, resolution: []const u8) ResourceFailureSpec {
    return .{
        .resource = "dynamic_file_resource",
        .operation = "read_resource",
        .phase = phase,
        .code = code,
        .category = category,
        .resolution = resolution,
    };
}
