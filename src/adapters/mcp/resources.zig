const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../app/context.zig");
const runtime_ux = @import("../../app/usecases/runtime_ux/workflows.zig");
const mcp_resource_errors = @import("resource_errors.zig");
const mcp_result = @import("result.zig");

pub fn registerResources(server: anytype, context_provider: anytype) !void {
    const Provider = @TypeOf(context_provider);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://workspace",
        .name = "Zigar Workspace",
        .description = "Current zigar workspace and backend configuration.",
        .mimeType = "text/plain",
        .handler = textResourceHandler(Provider, workspaceResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://zls/status",
        .name = "ZLS Status",
        .description = "Current ZLS session state and capability summary.",
        .mimeType = "application/json",
        .handler = jsonResourceHandler(Provider, zlsStatusResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://tools/capabilities",
        .name = "Zigar Tool Capabilities",
        .description = "Deterministic capability summary for zigar tool groups.",
        .mimeType = "application/json",
        .handler = textResourceHandler(Provider, catalogResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://tools/schema",
        .name = "Zigar Tool Schema",
        .description = "Compact zigar tool catalog, safety defaults, and discovery hints.",
        .mimeType = "application/json",
        .handler = textResourceHandler(Provider, catalogResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://workspace/import-graph",
        .name = "Workspace Import Graph",
        .description = "Heuristic Zig import graph for the active workspace.",
        .mimeType = "text/plain",
        .handler = textResourceHandler(Provider, importGraphResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://metrics",
        .name = "Zigar Metrics",
        .description = "Process-local zigar counters and backend state.",
        .mimeType = "application/json",
        .handler = jsonResourceHandler(Provider, metricsResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://jobs",
        .name = "Zigar Jobs",
        .description = "Process-local zigar job status and output tails.",
        .mimeType = "application/json",
        .handler = jsonResourceHandler(Provider, jobsResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://run/events",
        .name = "Zigar Run Events",
        .description = "Process-local zigar job event ring.",
        .mimeType = "application/json",
        .handler = jsonResourceHandler(Provider, runEventsResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://workspace/roots",
        .name = "Zigar Workspace Roots",
        .description = "Configured and client-synced workspace root guidance.",
        .mimeType = "application/json",
        .handler = jsonResourceHandler(Provider, workspaceRootsResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    server.setDynamicResourceHandler(dynamicResourceHandler(Provider), context_provider, mcp_result.deinitResourceContent);
    try server.addResourceTemplate(.{
        .uriTemplate = "zigar://file/{path}/symbols",
        .name = "File Symbols",
        .description = "Use zig_document_symbols or zig_decl_summary_json for the given workspace file.",
        .mimeType = "application/json",
    });
    try server.addResourceTemplate(.{
        .uriTemplate = "zigar://file/{path}/diagnostics",
        .name = "File Diagnostics",
        .description = "Use zig_diagnostics_all for the given workspace file.",
        .mimeType = "application/json",
    });
    try server.addResourceTemplate(.{
        .uriTemplate = "zigar://file/{path}/imports",
        .name = "File Imports",
        .description = "Use zig_import_graph_json and filter by path for import data.",
        .mimeType = "application/json",
    });
}

fn workspaceResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const body = runtime_ux.workspaceResourceText(allocator, context) catch |err| return resourceFailure(allocator, uri, .{
        .resource = "workspace",
        .operation = "read_resource",
        .phase = "build_workspace_resource",
        .code = "workspace_resource_failed",
        .category = "runtime_state",
        .resolution = "Retry the resource read; report this with the current zigar startup arguments if it persists.",
    }, err);
    return .{ .uri = uri, .mimeType = "text/plain", .text = body };
}

fn zlsStatusResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!std.json.Value {
    var value = runtime_ux.zlsStatusResourceValue(allocator, context) catch |err| return resourceValueFailure(allocator, uri, .{
        .resource = "zls_status",
        .operation = "read_resource",
        .phase = "build_status",
        .code = "zls_status_failed",
        .category = "lsp",
        .resolution = "Run zigar_doctor with probe_backends=false and retry the resource read after checking the ZLS session state.",
    }, err);
    if (context.zls_state.initialize_response) |response| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            const caps = serverCapabilities(p.value);
            var cap_json: std.ArrayList(u8) = .empty;
            errdefer cap_json.deinit(allocator);
            mcp_result.serializeValue(allocator, &cap_json, caps) catch |err| return resourceValueFailure(allocator, uri, .{
                .resource = "zls_status",
                .operation = "read_resource",
                .phase = "serialize_server_capabilities",
                .code = "zls_capabilities_serialization_failed",
                .category = "lsp",
                .resolution = "Retry after restarting the ZLS session; report this with zigar://zls/status output if it persists.",
            }, err);
            value.object.put(allocator, "server_capabilities_json", .{ .string = cap_json.toOwnedSlice(allocator) catch return error.OutOfMemory }) catch return error.OutOfMemory;
        }
    }
    return value;
}

fn catalogResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const body = runtime_ux.catalogResourceText(allocator, context) catch |err| return resourceFailure(allocator, uri, .{
        .resource = "tool_catalog",
        .operation = "read_resource",
        .phase = "render_catalog",
        .code = "tool_catalog_render_failed",
        .category = "catalog",
        .resolution = "Run zig build docs-check json-check to verify the generated tool catalog, then retry the resource read.",
    }, err);
    return .{ .uri = uri, .mimeType = "application/json", .text = body };
}

fn importGraphResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const body = runtime_ux.importGraphResourceText(allocator, context) catch |err| return resourceFailure(allocator, uri, .{
        .resource = "workspace_import_graph",
        .operation = "read_resource",
        .phase = "scan_import_graph",
        .code = "import_graph_failed",
        .category = "analysis",
        .resolution = "Run zig_import_graph_json for structured diagnostics, check workspace readability, then retry zigar://workspace/import-graph.",
        .details = &.{.{ .key = "workspace", .value = .{ .string = context.workspace.root } }},
    }, err);
    return .{ .uri = uri, .mimeType = "text/plain", .text = body };
}

fn metricsResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!std.json.Value {
    return runtime_ux.metricsResourceValue(allocator, context) catch |err| resourceValueFailure(allocator, uri, .{
        .resource = "metrics",
        .operation = "read_resource",
        .phase = "build_metrics",
        .code = "metrics_failed",
        .category = "runtime_state",
        .resolution = "Retry the resource read; report this with zigar_workspace_info if metrics cannot be produced.",
    }, err);
}

fn jobsResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!std.json.Value {
    return runtime_ux.jobsResourceValue(allocator, context) catch |err| resourceValueFailure(allocator, uri, .{
        .resource = "jobs",
        .operation = "read_resource",
        .phase = "build_jobs",
        .code = "jobs_failed",
        .category = "runtime_state",
        .resolution = "Retry the resource read; report this with zigar_run_events if retained job state cannot be produced.",
    }, err);
}

fn runEventsResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!std.json.Value {
    return runtime_ux.runEventsResourceValue(allocator, context) catch |err| resourceValueFailure(allocator, uri, .{
        .resource = "run_events",
        .operation = "read_resource",
        .phase = "build_events",
        .code = "run_events_failed",
        .category = "runtime_state",
        .resolution = "Retry the resource read; report this if process-local event state cannot be produced.",
    }, err);
}

fn workspaceRootsResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!std.json.Value {
    return runtime_ux.workspaceRootsResourceValue(allocator, context) catch |err| resourceValueFailure(allocator, uri, .{
        .resource = "workspace_roots",
        .operation = "read_resource",
        .phase = "build_roots",
        .code = "workspace_roots_failed",
        .category = "runtime_state",
        .resolution = "Retry the resource read after calling zigar_workspace_map.",
    }, err);
}

fn dynamicResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    if (!std.mem.startsWith(u8, uri, "zigar://file/")) return error.NotFound;
    const value = runtime_ux.dynamicResourceValue(allocator, context, uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => return resourceFailure(allocator, uri, dynamicResourceFailure("parse_dynamic_uri", "invalid_dynamic_resource_uri", "path_safety", "Use zigar://file/{path}/{symbols|diagnostics|imports} with a path inside the configured workspace."), err),
        error.PathOutsideWorkspace, error.EmptyPath, error.FileNotFound, error.AccessDenied, error.PermissionDenied => return resourceFailure(allocator, uri, dynamicResourceFailure("read_dynamic_file", "dynamic_resource_unavailable", "filesystem", "Confirm the file exists inside the configured workspace and retry the resource read."), err),
        else => return resourceFailure(allocator, uri, dynamicResourceFailure("build_dynamic_resource", "dynamic_resource_failed", "analysis", "Retry with zigar_resource_query for a structured tool_error and inspect the requested file."), err),
    };
    return jsonContent(allocator, uri, value);
}

fn textResourceHandler(
    comptime Provider: type,
    comptime handler: *const fn (std.mem.Allocator, app_context.RuntimeUxContext, []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent,
) *const fn (?*anyopaque, std.Io, std.mem.Allocator, []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return struct {
        fn call(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
            const context = runtimeContext(Provider, allocator, user_data, uri) catch |err| return contextFailure(allocator, uri, err);
            return handler(allocator, context, uri);
        }
    }.call;
}

fn jsonResourceHandler(
    comptime Provider: type,
    comptime handler: *const fn (std.mem.Allocator, app_context.RuntimeUxContext, []const u8) mcp.resources.ResourceError!std.json.Value,
) *const fn (?*anyopaque, std.Io, std.mem.Allocator, []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return struct {
        fn call(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
            const context = runtimeContext(Provider, allocator, user_data, uri) catch |err| return contextFailure(allocator, uri, err);
            const value = handler(allocator, context, uri) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return resourceFailure(allocator, uri, .{
                    .resource = "json_resource",
                    .operation = "read_resource",
                    .phase = "build_json",
                    .code = "json_resource_failed",
                    .category = "runtime_state",
                    .resolution = "Retry the resource read; report this zigar resource URI if it persists.",
                }, err),
            };
            return jsonContent(allocator, uri, value);
        }
    }.call;
}

fn dynamicResourceHandler(comptime Provider: type) *const fn (?*anyopaque, std.Io, std.mem.Allocator, []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return struct {
        fn call(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
            const context = runtimeContext(Provider, allocator, user_data, uri) catch |err| return contextFailure(allocator, uri, err);
            return dynamicResource(allocator, context, uri);
        }
    }.call;
}

fn runtimeContext(comptime Provider: type, allocator: std.mem.Allocator, user_data: ?*anyopaque, uri: []const u8) !app_context.RuntimeUxContext {
    _ = allocator;
    _ = uri;
    const ptr = user_data orelse return error.MissingRuntime;
    const provider: Provider = @ptrCast(@alignCast(ptr));
    return provider.runtimeUxContext();
}

fn jsonContent(allocator: std.mem.Allocator, uri: []const u8, value: std.json.Value) mcp.resources.ResourceError!mcp.resources.ResourceContent {
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

fn serverCapabilities(value: std.json.Value) std.json.Value {
    const result = switch (value) {
        .object => |obj| obj.get("result") orelse return .null,
        else => return .null,
    };
    return switch (result) {
        .object => |obj| obj.get("capabilities") orelse .null,
        else => .null,
    };
}

const ResourceFailureSpec = struct {
    resource: []const u8,
    operation: []const u8,
    phase: []const u8,
    code: []const u8,
    category: []const u8,
    retryable: bool = false,
    resolution: []const u8,
    details: []const mcp_resource_errors.Detail = &.{},
};

fn resourceFailure(allocator: std.mem.Allocator, uri: []const u8, spec: ResourceFailureSpec, err: anyerror) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return mcp_resource_errors.jsonContentFromError(allocator, .{
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

fn resourceValueFailure(allocator: std.mem.Allocator, uri: []const u8, spec: ResourceFailureSpec, err: anyerror) mcp.resources.ResourceError!std.json.Value {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return mcp_resource_errors.valueFromError(allocator, .{
        .uri = uri,
        .resource = spec.resource,
        .operation = spec.operation,
        .phase = spec.phase,
        .code = spec.code,
        .category = spec.category,
        .retryable = spec.retryable,
        .resolution = spec.resolution,
        .details = spec.details,
    }, err) catch return error.OutOfMemory;
}

fn contextFailure(allocator: std.mem.Allocator, uri: []const u8, err: anyerror) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return resourceFailure(allocator, uri, .{
        .resource = "registered_resource",
        .operation = "dispatch_resource",
        .phase = "resolve_runtime_context",
        .code = "missing_runtime_context",
        .category = "internal_contract",
        .resolution = "Restart the MCP server; resource handlers must be registered with a runtime UX context provider.",
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

const _resource_contract_tokens = [_][]const u8{
    "zigar://workspace",
    "zigar://zls/status",
    "zigar://tools/capabilities",
    "zigar://tools/schema",
    "zigar://workspace/import-graph",
    "zigar://metrics",
    "zigar://jobs",
    "zigar://run/events",
    "zigar://workspace/roots",
    "zigar://file/{path}/symbols",
    "zigar://file/{path}/diagnostics",
    "zigar://file/{path}/imports",
};

test {
    _ = registerResources;
    _ = _resource_contract_tokens;
}
