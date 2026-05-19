const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const analysis = zigar.analysis;
const catalog = zigar.catalog;
const json_result = zigar.json_result;
const resource_errors = zigar.resource_errors;
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

pub fn profilePrompt(_: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    const messages = allocator.alloc(mcp.prompts.PromptMessage, 1) catch return error.OutOfMemory;
    messages[0] = mcp.prompts.userMessage("Use zigar_workspace_info, zig_profile_plan, zig_profile_run, zig_flamegraph, and zig_flamegraph_diff to build a deterministic Zig profiling workflow. Do not edit source files unless an explicit tool argument requires apply=true.");
    return messages;
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
