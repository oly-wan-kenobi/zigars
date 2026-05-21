const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const mcp_server = zigar.mcp_server;
const runtime_mod = zigar.runtime;
const tool_metadata = zigar.tool_metadata;
const tool_registry = zigar.tool_registry;
const tool_handlers = @import("tool_handlers.zig");

const resources = @import("tools/resources.zig");
const json_result = zigar.json_result;
const resource_errors = zigar.resource_errors;

const App = runtime_mod.App;

pub fn registerTools(server: *mcp_server.Server, runtime: *App) !void {
    inline for (tool_metadata.specs) |spec| {
        try tool_registry.addTool(server, runtime.allocator, runtime, spec, tool_handlers.handlerFor(spec.id));
    }
}

pub fn registerResources(server: *mcp_server.Server, runtime: *App) !void {
    try server.addResourceWithDeinit(.{
        .uri = "zigar://workspace",
        .name = "Zigar Workspace",
        .description = "Current zigar workspace and backend configuration.",
        .mimeType = "text/plain",
        .handler = resourceHandler(resources.workspaceResource),
        .user_data = runtime,
    }, json_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://zls/status",
        .name = "ZLS Status",
        .description = "Current ZLS session state and capability summary.",
        .mimeType = "application/json",
        .handler = resourceHandler(resources.zlsStatusResource),
        .user_data = runtime,
    }, json_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://tools/capabilities",
        .name = "Zigar Tool Capabilities",
        .description = "Deterministic capability summary for zigar tool groups.",
        .mimeType = "application/json",
        .handler = resourceHandler(resources.capabilitiesResource),
        .user_data = runtime,
    }, json_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://tools/schema",
        .name = "Zigar Tool Schema",
        .description = "Compact zigar tool catalog, safety defaults, and discovery hints.",
        .mimeType = "application/json",
        .handler = resourceHandler(resources.schemaResource),
        .user_data = runtime,
    }, json_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://workspace/import-graph",
        .name = "Workspace Import Graph",
        .description = "Heuristic Zig import graph for the active workspace.",
        .mimeType = "text/plain",
        .handler = resourceHandler(resources.importGraphResource),
        .user_data = runtime,
    }, json_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://metrics",
        .name = "Zigar Metrics",
        .description = "Process-local zigar counters and backend state.",
        .mimeType = "application/json",
        .handler = resourceHandler(resources.metricsResource),
        .user_data = runtime,
    }, json_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://jobs",
        .name = "Zigar Jobs",
        .description = "Process-local zigar job status and output tails.",
        .mimeType = "application/json",
        .handler = resourceHandler(resources.jobsResource),
        .user_data = runtime,
    }, json_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://run/events",
        .name = "Zigar Run Events",
        .description = "Process-local zigar job event ring.",
        .mimeType = "application/json",
        .handler = resourceHandler(resources.runEventsResource),
        .user_data = runtime,
    }, json_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigar://workspace/roots",
        .name = "Zigar Workspace Roots",
        .description = "Configured and client-synced workspace root guidance.",
        .mimeType = "application/json",
        .handler = resourceHandler(resources.workspaceRootsResource),
        .user_data = runtime,
    }, json_result.deinitResourceContent);
    server.setDynamicResourceHandler(resourceHandler(resources.dynamicResource), runtime, json_result.deinitResourceContent);
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

pub fn registerPrompts(server: *mcp_server.Server, runtime: *App) !void {
    try server.addPromptWithDeinit(.{
        .name = "zigar_profile_workflow",
        .description = "Plan a deterministic Zig profiling workflow using zigar tools.",
        .title = "Zig Profiling Workflow",
        .handler = promptHandler(resources.profilePrompt),
        .user_data = runtime,
    }, json_result.deinitPromptMessages);
    inline for (.{ "zigar_compile_error_workflow", "zigar_test_workflow", "zigar_refactor_workflow", "zigar_api_change_workflow", "zigar_release_workflow", "zigar_perf_workflow" }) |name| {
        try server.addPromptWithDeinit(.{
            .name = name,
            .description = "Deterministic zigar workflow prompt.",
            .title = "Zigar Workflow",
            .handler = workflowPromptHandler(name),
            .user_data = runtime,
        }, json_result.deinitPromptMessages);
    }
}

fn resourceHandler(comptime handler: *const fn (*App, std.mem.Allocator, []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent) *const fn (?*anyopaque, std.Io, std.mem.Allocator, []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return struct {
        fn call(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
            const runtime: *App = @ptrCast(@alignCast(user_data orelse return resource_errors.jsonContentFromError(allocator, .{
                .uri = uri,
                .resource = "registered_resource",
                .operation = "dispatch_resource",
                .phase = "resolve_runtime",
                .code = "missing_runtime",
                .category = "internal_contract",
                .resolution = "Restart the MCP server; resource handlers must be registered with zigar runtime user_data.",
            }, error.MissingRuntime)));
            return handler(runtime, allocator, uri);
        }
    }.call;
}

fn promptHandler(comptime handler: *const fn (*App, std.mem.Allocator, ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage) *const fn (?*anyopaque, std.Io, std.mem.Allocator, ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    return struct {
        fn call(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, args: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
            const runtime: *App = @ptrCast(@alignCast(user_data orelse return error.GenerationFailed));
            return handler(runtime, allocator, args);
        }
    }.call;
}

fn workflowPromptHandler(comptime name: []const u8) *const fn (?*anyopaque, std.Io, std.mem.Allocator, ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
    return struct {
        fn call(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.prompts.PromptError![]const mcp.prompts.PromptMessage {
            const runtime: *App = @ptrCast(@alignCast(user_data orelse return error.GenerationFailed));
            return resources.workflowPromptNamed(runtime, allocator, name);
        }
    }.call;
}

test {
    _ = @import("server_tests.zig");
}
