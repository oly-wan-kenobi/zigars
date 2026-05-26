const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../app/context.zig");
const runtime_ux = @import("../../app/usecases/runtime_ux/workflows.zig");
const ports = @import("../../app/ports.zig");
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

const test_fakes = @import("../../testing/fakes/root.zig");

const ResourceTestProvider = struct {
    context: app_context.RuntimeUxContext,

    fn runtimeUxContext(self: *ResourceTestProvider) app_context.RuntimeUxContext {
        return self.context;
    }
};

fn resourceTestContext(
    command_runner: *test_fakes.FakeCommandRunner,
    workspace_store: *test_fakes.FakeWorkspaceStore,
    workspace_scanner: *test_fakes.FakeWorkspaceScanner,
    runtime_session: *test_fakes.FakeRuntimeSession,
    tool_catalog: ?ports.ToolCatalog,
) app_context.RuntimeUxContext {
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache" },
        .tool_paths = .{ .zig = "/bin/zig", .zls = "/bin/zls" },
        .timeouts = .{ .command_ms = 1000, .zls_ms = 2000 },
        .zls_state = .{
            .status = "connected",
            .running = true,
            .initialize_response = "{\"result\":{\"capabilities\":{\"hoverProvider\":true}}}",
            .restart_attempts = 1,
        },
        .command_runner = command_runner.port(),
        .workspace_store = workspace_store.port(),
        .workspace_scanner = workspace_scanner.port(),
        .runtime_session = runtime_session.port(),
        .tool_catalog = tool_catalog,
    };
}

fn seedResourceJob(session: *test_fakes.FakeRuntimeSession) !void {
    const runtime = session.port();
    try runtime.ensureDefaultRoot("/repo");
    const job = try runtime.startJob("check", "/bin/zig build", 1000);
    _ = try runtime.finishJob(job.id, .{
        .status = .completed,
        .ok = true,
        .duration_ms = 7,
        .term = "exited",
        .exit_code = 0,
        .stdout_tail = "ok\n",
        .stderr_tail = "",
        .stdout_truncated = false,
        .stderr_truncated = false,
    });
    _ = try runtime.subscribe("zigar://jobs");
}

fn failingJsonResource(_: std.mem.Allocator, _: app_context.RuntimeUxContext, _: []const u8) mcp.resources.ResourceError!std.json.Value {
    return @as(mcp.resources.ResourceError, error.ReadFailed);
}

fn oomJsonResource(_: std.mem.Allocator, _: app_context.RuntimeUxContext, _: []const u8) mcp.resources.ResourceError!std.json.Value {
    return error.OutOfMemory;
}

test "MCP resource adapter renders direct app resource values" {
    var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var session = test_fakes.FakeRuntimeSession{};
    defer session.deinit(std.testing.allocator);
    var catalog = test_fakes.FakeToolCatalog.init("{\"groups\":[]}");
    var context = resourceTestContext(&commands, &workspace, &scanner, &session, catalog.port());
    var command_calls: usize = 3;
    context.counters.command_calls = &command_calls;
    context.caches.backend_probe.zig = true;

    try seedResourceJob(&session);
    try scanner.expectScan(.{ .max_files = runtime_ux.max_roots * 12 + 8, .provenance = "static_analysis.import_graph" }, &.{"src/main.zig"});
    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = 512 * 1024,
        .provenance = "static_analysis.import_graph",
    },
        \\const std = @import("std");
        \\const local = @import("local.zig");
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const zls = try zlsStatusResource(allocator, context, "zigar://zls/status");
    try std.testing.expect(zls.object.get("server_capabilities_json") != null);

    const catalog_content = try catalogResource(allocator, context, "zigar://tools/schema");
    try std.testing.expectEqualStrings("application/json", catalog_content.mimeType.?);
    try std.testing.expectEqualStrings("{\"groups\":[]}", catalog_content.text.?);

    const import_graph = try importGraphResource(allocator, context, "zigar://workspace/import-graph");
    try std.testing.expect(std.mem.indexOf(u8, import_graph.text.?, "local.zig") != null);

    const metrics = try metricsResource(allocator, context, "zigar://metrics");
    try std.testing.expectEqual(@as(i64, 3), metrics.object.get("command_calls").?.integer);

    const jobs = try jobsResource(allocator, context, "zigar://jobs");
    try std.testing.expectEqual(@as(i64, 1), jobs.object.get("job_count").?.integer);

    const events = try runEventsResource(allocator, context, "zigar://run/events");
    try std.testing.expectEqual(@as(i64, 2), events.object.get("event_count").?.integer);

    const roots = try workspaceRootsResource(allocator, context, "zigar://workspace/roots");
    try std.testing.expectEqualStrings("root-1", roots.object.get("selected_root_id").?.string);

    try workspace.verify();
    try scanner.verify();
}

test "MCP resource handlers resolve runtime context and serialize JSON" {
    var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var session = test_fakes.FakeRuntimeSession{};
    defer session.deinit(std.testing.allocator);
    var catalog = test_fakes.FakeToolCatalog.init("{}");
    var provider = ResourceTestProvider{ .context = resourceTestContext(&commands, &workspace, &scanner, &session, catalog.port()) };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text_handler = textResourceHandler(*ResourceTestProvider, workspaceResource);
    const workspace_content = try text_handler(&provider, std.testing.io, allocator, "zigar://workspace");
    try std.testing.expect(std.mem.indexOf(u8, workspace_content.text.?, "workspace=/repo") != null);

    const json_handler = jsonResourceHandler(*ResourceTestProvider, metricsResource);
    const metrics_content = try json_handler(&provider, std.testing.io, allocator, "zigar://metrics");
    try std.testing.expectEqualStrings("application/json", metrics_content.mimeType.?);
    try std.testing.expect(std.mem.indexOf(u8, metrics_content.text.?, "\"command_calls\"") != null);

    const failing_handler = jsonResourceHandler(*ResourceTestProvider, failingJsonResource);
    const error_content = try failing_handler(&provider, std.testing.io, allocator, "zigar://metrics");
    try std.testing.expect(std.mem.indexOf(u8, error_content.text.?, "json_resource_failed") != null);

    const oom_handler = jsonResourceHandler(*ResourceTestProvider, oomJsonResource);
    try std.testing.expectError(error.OutOfMemory, oom_handler(&provider, std.testing.io, allocator, "zigar://metrics"));

    const missing_context = try text_handler(null, std.testing.io, allocator, "zigar://workspace");
    try std.testing.expect(std.mem.indexOf(u8, missing_context.text.?, "missing_runtime_context") != null);
}

test "MCP dynamic resource handler maps success and app-layer errors" {
    var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var session = test_fakes.FakeRuntimeSession{};
    defer session.deinit(std.testing.allocator);
    var catalog = test_fakes.FakeToolCatalog.init("{}");
    var provider = ResourceTestProvider{ .context = resourceTestContext(&commands, &workspace, &scanner, &session, catalog.port()) };

    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = runtime_ux.max_resource_read,
        .provenance = "runtime_ux.dynamic_resource",
    },
        \\const std = @import("std");
        \\pub fn main() void {}
    );
    try workspace.expectReadError(.{
        .path = "missing.zig",
        .max_bytes = runtime_ux.max_resource_read,
        .provenance = "runtime_ux.dynamic_resource",
    }, error.FileNotFound);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const handler = dynamicResourceHandler(*ResourceTestProvider);

    const success = try handler(&provider, std.testing.io, allocator, "zigar://file/src/main.zig/imports");
    try std.testing.expect(std.mem.indexOf(u8, success.text.?, "\"resource_kind\": \"imports\"") != null);

    try std.testing.expectError(error.NotFound, handler(&provider, std.testing.io, allocator, "zigar://metrics"));

    const invalid_uri = try handler(&provider, std.testing.io, allocator, "zigar://file/no-mode");
    try std.testing.expect(std.mem.indexOf(u8, invalid_uri.text.?, "invalid_dynamic_resource_uri") != null);

    const missing_file = try handler(&provider, std.testing.io, allocator, "zigar://file/missing.zig/imports");
    try std.testing.expect(std.mem.indexOf(u8, missing_file.text.?, "dynamic_resource_unavailable") != null);

    const analysis_failure = try handler(&provider, std.testing.io, allocator, "zigar://file/unexpected.zig/imports");
    try std.testing.expect(std.mem.indexOf(u8, analysis_failure.text.?, "dynamic_resource_failed") != null);

    const missing_context = try handler(null, std.testing.io, allocator, "zigar://file/src/main.zig/imports");
    try std.testing.expect(std.mem.indexOf(u8, missing_context.text.?, "missing_runtime_context") != null);

    try workspace.verify();
}

test "MCP resource helpers produce structured failures and capability views" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const failure = try resourceFailure(allocator, "zigar://x", .{
        .resource = "workspace",
        .operation = "read",
        .phase = "phase",
        .code = "failed",
        .category = "test",
        .retryable = true,
        .resolution = "retry",
        .details = &.{.{ .key = "detail", .value = .{ .string = "value" } }},
    }, error.FileNotFound);
    try std.testing.expect(std.mem.indexOf(u8, failure.text.?, "\"detail\": \"value\"") != null);

    const value_failure = try resourceValueFailure(allocator, "zigar://x", .{
        .resource = "workspace",
        .operation = "read",
        .phase = "phase",
        .code = "failed",
        .category = "test",
        .resolution = "retry",
    }, error.AccessDenied);
    try std.testing.expectEqualStrings("AccessDenied", value_failure.object.get("error").?.string);
    try std.testing.expectError(error.OutOfMemory, resourceValueFailure(allocator, "zigar://x", .{
        .resource = "workspace",
        .operation = "read",
        .phase = "phase",
        .code = "failed",
        .category = "test",
        .resolution = "retry",
    }, error.OutOfMemory));

    const context_error = try contextFailure(allocator, "zigar://x", error.MissingRuntime);
    try std.testing.expect(std.mem.indexOf(u8, context_error.text.?, "missing_runtime_context") != null);

    const dynamic_spec = dynamicResourceFailure("phase", "code", "category", "resolution");
    try std.testing.expectEqualStrings("dynamic_file_resource", dynamic_spec.resource);

    var caps_obj = std.json.ObjectMap.empty;
    try caps_obj.put(allocator, "hoverProvider", .{ .bool = true });
    var result_obj = std.json.ObjectMap.empty;
    try result_obj.put(allocator, "capabilities", .{ .object = caps_obj });
    var root_obj = std.json.ObjectMap.empty;
    try root_obj.put(allocator, "result", .{ .object = result_obj });
    try std.testing.expectEqual(std.meta.Tag(std.json.Value).object, std.meta.activeTag(serverCapabilities(.{ .object = root_obj })));
    try std.testing.expectEqual(.null, serverCapabilities(.{ .bool = true }));

    const empty_root = std.json.ObjectMap.empty;
    try std.testing.expectEqual(.null, serverCapabilities(.{ .object = empty_root }));

    var result_not_object = std.json.ObjectMap.empty;
    try result_not_object.put(allocator, "result", .{ .bool = true });
    try std.testing.expectEqual(.null, serverCapabilities(.{ .object = result_not_object }));

    const missing_caps_result = std.json.ObjectMap.empty;
    var missing_caps_root = std.json.ObjectMap.empty;
    try missing_caps_root.put(allocator, "result", .{ .object = missing_caps_result });
    try std.testing.expectEqual(.null, serverCapabilities(.{ .object = missing_caps_root }));

    const json = try jsonContent(allocator, "zigar://json", .{ .bool = true });
    try std.testing.expectEqualStrings("true", std.mem.trim(u8, json.text.?, "\n "));
}

test "MCP JSON resource content cleans partial buffer on allocation failure" {
    var fail_index: usize = 0;
    while (fail_index < 16) : (fail_index += 1) {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        const allocator = failing.allocator();

        var obj = std.json.ObjectMap.empty;
        try obj.put(backing.allocator(), "kind", .{ .string = "value" });
        if (jsonContent(allocator, "zigar://json", .{ .object = obj })) |content| {
            mcp_result.deinitResourceContent(allocator, content);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "MCP resource adapter maps remaining failure branches" {
    var commands = test_fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = test_fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = test_fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var session = test_fakes.FakeRuntimeSession{};
    defer session.deinit(std.testing.allocator);
    var catalog = test_fakes.FakeToolCatalog.init("{}");
    const context = resourceTestContext(&commands, &workspace, &scanner, &session, catalog.port());

    try scanner.expectScanError(.{ .max_files = runtime_ux.max_roots * 12 + 8, .provenance = "static_analysis.import_graph" }, error.AccessDenied);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const import_error = try importGraphResource(arena.allocator(), context, "zigar://workspace/import-graph");
    try std.testing.expect(std.mem.indexOf(u8, import_error.text.?, "\"workspace\": \"/repo\"") != null);

    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = runtime_ux.max_resource_read,
        .provenance = "runtime_ux.dynamic_resource",
    },
        \\const std = @import("std");
        \\pub fn main() void {}
    );
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, dynamicResource(failing.allocator(), context, "zigar://file/src/main.zig/imports"));

    try scanner.verify();
    try workspace.verify();
}

test "MCP resource value failure and ZLS status clean up on allocation failure" {
    var fail_index: usize = 0;
    while (fail_index < 48) : (fail_index += 1) {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        const allocator = failing.allocator();

        if (resourceValueFailure(allocator, "zigar://x", .{
            .resource = "workspace",
            .operation = "read",
            .phase = "phase",
            .code = "failed",
            .category = "test",
            .resolution = "retry",
        }, error.AccessDenied)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }

    fail_index = 0;
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
        var catalog = test_fakes.FakeToolCatalog.init("{}");
        const context = resourceTestContext(&commands, &workspace, &scanner, &session, catalog.port());

        if (zlsStatusResource(allocator, context, "zigar://zls/status")) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}
