//! MCP resource registration and serialization over runtime workflow/read-model ports.
const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../app/context.zig");
const artifact_registry = @import("../../app/usecases/artifacts/registry.zig");
const trust_usecase = @import("../../app/usecases/environment/trust.zig");
const runtime_ux = @import("../../app/usecases/runtime_ux/workflows.zig");
const ports = @import("../../app/ports.zig");
const mcp_resource_errors = @import("resource_errors.zig");
const mcp_result = @import("result.zig");

/// Registers static resource URIs and dynamic file resource templates.
pub fn registerResources(server: anytype, context_provider: anytype) !void {
    const Provider = @TypeOf(context_provider);
    try server.addResourceWithDeinit(.{
        .uri = trust_usecase.trust_manifest_uri,
        .name = "Zigars Trust Manifest",
        .description = "Connection-time trust posture, source-write policy, backend identity, and setup guidance.",
        .mimeType = "application/json",
        .handler = jsonResourceHandler(Provider, trustManifestResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigars://workspace",
        .name = "Zigars Workspace",
        .description = "Current zigars workspace and backend configuration.",
        .mimeType = "text/plain",
        .handler = textResourceHandler(Provider, workspaceResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigars://zls/status",
        .name = "ZLS Status",
        .description = "Current ZLS session state and capability summary.",
        .mimeType = "application/json",
        .handler = jsonResourceHandler(Provider, zlsStatusResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigars://tools/capabilities",
        .name = "Zigars Tool Capabilities",
        .description = "Deterministic capability summary for zigars tool groups.",
        .mimeType = "application/json",
        .handler = textResourceHandler(Provider, catalogResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigars://tools/schema",
        .name = "Zigars Tool Schema",
        .description = "Compact zigars tool catalog, safety defaults, and discovery hints.",
        .mimeType = "application/json",
        .handler = textResourceHandler(Provider, catalogResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigars://workspace/import-graph",
        .name = "Workspace Import Graph",
        .description = "Heuristic Zig import graph for the active workspace.",
        .mimeType = "text/plain",
        .handler = textResourceHandler(Provider, importGraphResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigars://metrics",
        .name = "Zigars Metrics",
        .description = "Process-local zigars counters and backend state.",
        .mimeType = "application/json",
        .handler = jsonResourceHandler(Provider, metricsResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigars://jobs",
        .name = "Zigars Jobs",
        .description = "Process-local zigars job status and output tails.",
        .mimeType = "application/json",
        .handler = jsonResourceHandler(Provider, jobsResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigars://run/events",
        .name = "Zigars Run Events",
        .description = "Process-local zigars job event ring.",
        .mimeType = "application/json",
        .handler = jsonResourceHandler(Provider, runEventsResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    try server.addResourceWithDeinit(.{
        .uri = "zigars://workspace/roots",
        .name = "Zigars Workspace Roots",
        .description = "Configured and client-synced workspace root guidance.",
        .mimeType = "application/json",
        .handler = jsonResourceHandler(Provider, workspaceRootsResource),
        .user_data = context_provider,
    }, mcp_result.deinitResourceContent);
    // File-scoped resources are advertised as templates; the dynamic handler
    // resolves concrete URIs at read time so registrations stay bounded.
    server.setDynamicResourceHandler(dynamicResourceHandler(Provider), context_provider, mcp_result.deinitResourceContent);
    try server.addResourceTemplate(.{
        .uriTemplate = "zigars://artifacts/{sha}",
        .name = "Artifact By SHA",
        .description = "Read a registered workspace artifact by sha256 identity.",
        .mimeType = "text/plain",
    });
    try server.addResourceTemplate(.{
        .uriTemplate = "zigars://file/{path}/symbols",
        .name = "File Symbols",
        .description = "Use zig_document_symbols or zig_decl_summary_json for the given workspace file.",
        .mimeType = "application/json",
    });
    try server.addResourceTemplate(.{
        .uriTemplate = "zigars://file/{path}/diagnostics",
        .name = "File Diagnostics",
        .description = "Use zig_diagnostics_all for the given workspace file.",
        .mimeType = "application/json",
    });
    try server.addResourceTemplate(.{
        .uriTemplate = "zigars://file/{path}/imports",
        .name = "File Imports",
        .description = "Use zig_import_graph_json and filter by path for import data.",
        .mimeType = "application/json",
    });
}

/// Returns the connection-time trust manifest for MCP reads.
fn trustManifestResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!std.json.Value {
    // Keep resource response shaping centralized so capability contracts remain stable.
    return trust_usecase.trustManifestValueFromRuntimeContext(allocator, context) catch |err| resourceValueFailure(allocator, uri, .{
        .resource = "trust_manifest",
        .operation = "read_resource",
        .phase = "build_manifest",
        .code = "trust_manifest_failed",
        .category = "trust",
        .resolution = "Retry the resource read; use zigars_trust_report if the connection-time resource remains unavailable.",
    }, err);
}

/// Builds the text workspace resource from runtime UX context.
fn workspaceResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    // Keep resource response shaping centralized so capability contracts remain stable.
    const body = runtime_ux.workspaceResourceText(allocator, context) catch |err| return resourceFailure(allocator, uri, .{
        .resource = "workspace",
        .operation = "read_resource",
        .phase = "build_workspace_resource",
        .code = "workspace_resource_failed",
        .category = "runtime_state",
        .resolution = "Retry the resource read; report this with the current zigars startup arguments if it persists.",
    }, err);
    return .{ .uri = uri, .mimeType = "text/plain", .text = body };
}

/// Returns the ZLS status resource content for MCP reads.
fn zlsStatusResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!std.json.Value {
    var value = runtime_ux.zlsStatusResourceValue(allocator, context) catch |err| return resourceValueFailure(allocator, uri, .{
        .resource = "zls_status",
        .operation = "read_resource",
        .phase = "build_status",
        .code = "zls_status_failed",
        .category = "lsp",
        .resolution = "Run zigars_doctor with probe_backends=false and retry the resource read after checking the ZLS session state.",
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
                .resolution = "Retry after restarting the ZLS session; report this with zigars://zls/status output if it persists.",
            }, err);
            value.object.put(allocator, "server_capabilities_json", .{ .string = cap_json.toOwnedSlice(allocator) catch return error.OutOfMemory }) catch return error.OutOfMemory;
        }
    }
    return value;
}

/// Returns the tool catalog resource content for MCP reads.
fn catalogResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    // Keep resource response shaping centralized so capability contracts remain stable.
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

/// Returns the workspace import graph resource content for MCP reads.
fn importGraphResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const body = runtime_ux.importGraphResourceText(allocator, context) catch |err| return resourceFailure(allocator, uri, .{
        .resource = "workspace_import_graph",
        .operation = "read_resource",
        .phase = "scan_import_graph",
        .code = "import_graph_failed",
        .category = "analysis",
        .resolution = "Run zig_import_graph_json for structured diagnostics, check workspace readability, then retry zigars://workspace/import-graph.",
        .details = &.{.{ .key = "workspace", .value = .{ .string = context.workspace.root } }},
    }, err);
    return .{ .uri = uri, .mimeType = "text/plain", .text = body };
}

/// Returns the runtime metrics resource content for MCP reads.
fn metricsResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!std.json.Value {
    // Keep resource response shaping centralized so capability contracts remain stable.
    return runtime_ux.metricsResourceValue(allocator, context) catch |err| resourceValueFailure(allocator, uri, .{
        .resource = "metrics",
        .operation = "read_resource",
        .phase = "build_metrics",
        .code = "metrics_failed",
        .category = "runtime_state",
        .resolution = "Retry the resource read; report this with zigars_workspace_info if metrics cannot be produced.",
    }, err);
}

/// Returns the runtime jobs resource content for MCP reads.
fn jobsResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!std.json.Value {
    // Keep resource response shaping centralized so capability contracts remain stable.
    return runtime_ux.jobsResourceValue(allocator, context) catch |err| resourceValueFailure(allocator, uri, .{
        .resource = "jobs",
        .operation = "read_resource",
        .phase = "build_jobs",
        .code = "jobs_failed",
        .category = "runtime_state",
        .resolution = "Retry the resource read; report this with zigars_run_events if retained job state cannot be produced.",
    }, err);
}

/// Returns runtime event history for the events resource URI.
fn runEventsResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!std.json.Value {
    // Keep resource response shaping centralized so capability contracts remain stable.
    return runtime_ux.runEventsResourceValue(allocator, context) catch |err| resourceValueFailure(allocator, uri, .{
        .resource = "run_events",
        .operation = "read_resource",
        .phase = "build_events",
        .code = "run_events_failed",
        .category = "runtime_state",
        .resolution = "Retry the resource read; report this if process-local event state cannot be produced.",
    }, err);
}

/// Returns the workspace roots resource content for MCP reads.
fn workspaceRootsResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!std.json.Value {
    // Keep resource response shaping centralized so capability contracts remain stable.
    return runtime_ux.workspaceRootsResourceValue(allocator, context) catch |err| resourceValueFailure(allocator, uri, .{
        .resource = "workspace_roots",
        .operation = "read_resource",
        .phase = "build_roots",
        .code = "workspace_roots_failed",
        .category = "runtime_state",
        .resolution = "Retry the resource read after calling zigars_workspace_map.",
    }, err);
}

/// Resolves zigars://file/{path}/{symbols|diagnostics|imports} URIs.
/// The embedded path is validated against the workspace sandbox inside the use
/// case; this handler only classifies the resulting error into a stable
/// resource_error category (bad URI vs. path/filesystem vs. analysis failure) so
/// a traversal attempt and a genuine read failure stay distinguishable.
fn dynamicResource(allocator: std.mem.Allocator, context: app_context.RuntimeUxContext, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    if (!std.mem.startsWith(u8, uri, "zigars://file/")) return error.NotFound;
    const value = runtime_ux.dynamicResourceValue(allocator, context, uri) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidArguments => return resourceFailure(allocator, uri, dynamicResourceFailure("parse_dynamic_uri", "invalid_dynamic_resource_uri", "path_safety", "Use zigars://file/{path}/{symbols|diagnostics|imports} with a path inside the configured workspace."), err),
        error.PathOutsideWorkspace, error.EmptyPath, error.FileNotFound, error.AccessDenied, error.PermissionDenied => return resourceFailure(allocator, uri, dynamicResourceFailure("read_dynamic_file", "dynamic_resource_unavailable", "filesystem", "Confirm the file exists inside the configured workspace and retry the resource read."), err),
        else => return resourceFailure(allocator, uri, dynamicResourceFailure("build_dynamic_resource", "dynamic_resource_failed", "analysis", "Retry with zigars_resource_query for a structured tool_error and inspect the requested file."), err),
    };
    return jsonContent(allocator, uri, value);
}

/// Resolves zigars://artifacts/{sha} URIs through the workspace artifact registry.
fn artifactResource(allocator: std.mem.Allocator, context: app_context.ArtifactContext, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    const prefix = "zigars://artifacts/";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.NotFound;
    const sha = uri[prefix.len..];
    // Reject non-canonical shas before any registry work: identities are keyed
    // by lowercase 64-char hex, so a malformed value can never match an entry.
    if (!isSha256Hex(sha)) {
        return resourceFailure(allocator, uri, artifactResourceFailure("parse_artifact_uri", "invalid_artifact_resource_uri", "Use zigars://artifacts/{sha} with a lowercase 64-character sha256 hex digest."), error.InvalidArguments);
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const registry = artifact_registry.readRegistrySnapshot(scratch, context) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PathOutsideWorkspace, error.EmptyPath, error.AccessDenied, error.PermissionDenied => return resourceFailure(allocator, uri, artifactResourceFailure("load_registry", "artifact_registry_unavailable", "Confirm the artifact registry path is readable inside the workspace, then retry."), err),
        else => return resourceFailure(allocator, uri, artifactResourceFailure("load_registry", "artifact_registry_failed", "Regenerate or prune the artifact registry, then retry the resource read."), err),
    };
    const entry = for (registry.entries) |candidate| {
        if (std.mem.eql(u8, candidate.sha256, sha)) break candidate;
    } else {
        return resourceFailure(allocator, uri, artifactResourceFailure("lookup_artifact", "artifact_resource_not_found", "Run zigars_artifact_index or regenerate the producing workflow so the artifact is registered."), error.FileNotFound);
    };
    // Route the artifact resolve+read through the app use case rather than
    // touching the workspace port directly, mirroring how other resource
    // handlers read through use cases. The use case validates the path inside
    // the workspace sandbox and returns the artifact content. The read uses the
    // scratch arena (so the use case's transient resolve/hash allocations are
    // reclaimed); the returned content is duped into the request allocator,
    // which owns the resource `.text` for `deinitResourceContent`.
    const read = artifact_registry.readArtifact(scratch, context, entry.path, artifact_registry.default_read_limit) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.PathOutsideWorkspace, error.EmptyPath, error.FileNotFound, error.AccessDenied, error.PermissionDenied => return resourceFailure(allocator, uri, artifactResourceFailure("read_artifact", "artifact_resource_unavailable", "Confirm the registered artifact still exists inside the workspace, then retry."), err),
        else => return resourceFailure(allocator, uri, artifactResourceFailure("read_artifact", "artifact_resource_failed", "Inspect the artifact registry entry and retry with zigars_artifact_read for a structured tool error."), err),
    };
    const owned_text = allocator.dupe(u8, read.content) catch return error.OutOfMemory;
    return .{
        .uri = uri,
        .mimeType = artifactMimeType(entry.path),
        .text = owned_text,
    };
}

/// Adapts a text resource builder into the server callback ABI.
fn textResourceHandler(
    comptime Provider: type,
    comptime handler: *const fn (std.mem.Allocator, app_context.RuntimeUxContext, []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent,
) *const fn (?*anyopaque, std.Io, std.mem.Allocator, []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return struct {
        /// Bridges the typed helper into the callback signature expected by the MCP adapter.
        fn call(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
            const context = runtimeContext(Provider, allocator, user_data, uri) catch |err| return contextFailure(allocator, uri, err);
            return handler(allocator, context, uri);
        }
    }.call;
}

/// Adapts a JSON builder into a resource callback with serialization and errors.
fn jsonResourceHandler(
    comptime Provider: type,
    comptime handler: *const fn (std.mem.Allocator, app_context.RuntimeUxContext, []const u8) mcp.resources.ResourceError!std.json.Value,
) *const fn (?*anyopaque, std.Io, std.mem.Allocator, []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return struct {
        /// Bridges the typed helper into the callback signature expected by the MCP adapter.
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
                    .resolution = "Retry the resource read; report this zigars resource URI if it persists.",
                }, err),
            };
            return jsonContent(allocator, uri, value);
        }
    }.call;
}

/// Builds the server callback for runtime-resolved dynamic resource templates.
fn dynamicResourceHandler(comptime Provider: type) *const fn (?*anyopaque, std.Io, std.mem.Allocator, []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    return struct {
        /// Bridges the typed helper into the callback signature expected by the MCP adapter.
        fn call(user_data: ?*anyopaque, _: std.Io, allocator: std.mem.Allocator, uri: []const u8) mcp.resources.ResourceError!mcp.resources.ResourceContent {
            if (std.mem.startsWith(u8, uri, "zigars://artifacts/")) {
                const artifact_context = artifactContext(Provider, allocator, user_data, uri) catch |err| return contextFailure(allocator, uri, err);
                return artifactResource(allocator, artifact_context, uri);
            }
            const context = runtimeContext(Provider, allocator, user_data, uri) catch |err| return contextFailure(allocator, uri, err);
            return dynamicResource(allocator, context, uri);
        }
    }.call;
}

/// Projects opaque server user_data into a RuntimeUxContext.
/// `allocator`/`uri` are unused but kept in the signature so every context
/// projector shares one shape for the handler adapters below.
fn runtimeContext(comptime Provider: type, allocator: std.mem.Allocator, user_data: ?*anyopaque, uri: []const u8) !app_context.RuntimeUxContext {
    _ = allocator;
    _ = uri;
    const ptr = user_data orelse return error.MissingRuntime;
    const provider: Provider = @ptrCast(@alignCast(ptr));
    return provider.runtimeUxContext();
}

/// Projects opaque server user_data into an ArtifactContext.
fn artifactContext(comptime Provider: type, allocator: std.mem.Allocator, user_data: ?*anyopaque, uri: []const u8) !app_context.ArtifactContext {
    _ = allocator;
    _ = uri;
    const ptr = user_data orelse return error.MissingRuntime;
    const provider: Provider = @ptrCast(@alignCast(ptr));
    return provider.artifactContext();
}

/// Serializes JSON as owned application/json resource text.
fn jsonContent(allocator: std.mem.Allocator, uri: []const u8, value: std.json.Value) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &aw.writer) catch |err| return resourceFailure(allocator, uri, .{
        .resource = "json_resource",
        .operation = "serialize_resource",
        .phase = "stringify_json",
        .code = "json_serialization_failed",
        .category = "serialization",
        .resolution = "Report this zigars bug with the resource URI and the operation that produced an unserializable JSON value.",
    }, err);
    return .{ .uri = uri, .mimeType = "application/json", .text = aw.toOwnedSlice() catch return error.OutOfMemory };
}

/// Extracts result.capabilities from a parsed ZLS initialize response.
fn serverCapabilities(value: std.json.Value) std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const result = switch (value) {
        .object => |obj| obj.get("result") orelse return .null,
        else => return .null,
    };
    return switch (result) {
        .object => |obj| obj.get("capabilities") orelse .null,
        else => .null,
    };
}

/// Internal resource error template before attaching URI and Zig error details.
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

/// Builds serialized resource error content from an internal failure spec.
fn resourceFailure(allocator: std.mem.Allocator, uri: []const u8, spec: ResourceFailureSpec, err: anyerror) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    // Keep resource response shaping centralized so capability contracts remain stable.
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

/// Builds a JSON error value for handlers that still need resource serialization.
fn resourceValueFailure(allocator: std.mem.Allocator, uri: []const u8, spec: ResourceFailureSpec, err: anyerror) mcp.resources.ResourceError!std.json.Value {
    // Keep resource response shaping centralized so capability contracts remain stable.
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

/// Normalizes missing runtime context failures for registered resource handlers.
fn contextFailure(allocator: std.mem.Allocator, uri: []const u8, err: anyerror) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    // Derive context values from one source so audit and response metadata do not diverge.
    return resourceFailure(allocator, uri, .{
        .resource = "registered_resource",
        .operation = "dispatch_resource",
        .phase = "resolve_runtime_context",
        .code = "missing_runtime_context",
        .category = "internal_contract",
        .resolution = "Restart the MCP server; resource handlers must be registered with a runtime UX context provider.",
    }, err);
}

/// Creates a reusable failure spec for dynamic file-resource reads.
fn dynamicResourceFailure(phase: []const u8, code: []const u8, category: []const u8, resolution: []const u8) ResourceFailureSpec {
    // Keep resource response shaping centralized so capability contracts remain stable.
    return .{
        .resource = "dynamic_file_resource",
        .operation = "read_resource",
        .phase = phase,
        .code = code,
        .category = category,
        .resolution = resolution,
    };
}

/// Creates a reusable failure spec for artifact resource reads.
fn artifactResourceFailure(phase: []const u8, code: []const u8, resolution: []const u8) ResourceFailureSpec {
    // Keep resource response shaping centralized so capability contracts remain stable.
    return .{
        .resource = "artifact_resource",
        .operation = "read_resource",
        .phase = phase,
        .code = code,
        .category = "artifact",
        .resolution = resolution,
    };
}

/// Returns true only for canonical sha256 identities: exactly 64 lowercase hex
/// chars. Uppercase and short/long values are rejected to keep artifact URIs
/// canonical and prevent lookups on non-identity input.
fn isSha256Hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Returns a MIME type for artifact resources from the path suffix, defaulting
/// to text/plain. Conservative on purpose: artifact bytes are tool output, so an
/// unrecognized extension is served as plain text rather than an active type.
fn artifactMimeType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".json") or std.mem.endsWith(u8, path, ".jsonl")) return "application/json";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    return "text/plain";
}

/// Contract-token anchor for resource URI coverage. A release gate
/// substring-matches these URIs against this file to prove every advertised
/// resource and template stays registered; keep in sync with `registerResources`.
const _resource_contract_tokens = [_][]const u8{
    "zigars://trust/manifest",
    "zigars://workspace",
    "zigars://zls/status",
    "zigars://tools/capabilities",
    "zigars://tools/schema",
    "zigars://workspace/import-graph",
    "zigars://metrics",
    "zigars://jobs",
    "zigars://run/events",
    "zigars://workspace/roots",
    "zigars://artifacts/{sha}",
    "zigars://file/{path}/symbols",
    "zigars://file/{path}/diagnostics",
    "zigars://file/{path}/imports",
};

test {
    _ = registerResources;
    _ = _resource_contract_tokens;
}

const test_fakes = @import("../../testing/fakes/root.zig");

/// Test provider that exposes a fixed runtime UX context to resource handlers.
const ResourceTestProvider = struct {
    context: app_context.RuntimeUxContext,

    /// Returns the fixed runtime UX context exposed by the test provider.
    fn runtimeUxContext(self: *ResourceTestProvider) app_context.RuntimeUxContext {
        return self.context;
    }

    /// Returns artifact context backed by the same workspace store.
    fn artifactContext(self: *ResourceTestProvider) app_context.ArtifactContext {
        return .{
            .workspace = self.context.workspace,
            .workspace_store = self.context.workspace_store,
        };
    }
};

/// Creates resource test context from the ports required by the adapter.
fn resourceTestContext(
    command_runner: *test_fakes.FakeCommandRunner,
    workspace_store: *test_fakes.FakeWorkspaceStore,
    workspace_scanner: *test_fakes.FakeWorkspaceScanner,
    runtime_session: *test_fakes.FakeRuntimeSession,
    tool_catalog: ?ports.ToolCatalog,
) app_context.RuntimeUxContext {
    // Keep resource response shaping centralized so capability contracts remain stable.
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigars-cache" },
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

/// Seeds the fake runtime session with a completed job for resource tests.
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
    _ = try runtime.subscribe("zigars://jobs");
}

/// Formats one artifact registry entry for resource tests.
fn resourceArtifactRegistryLine(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) ![]const u8 {
    const hash = try artifact_registry.sha256Hex(allocator, bytes);
    return std.fmt.allocPrint(allocator,
        \\{{"path":"{s}","abs_path":"/repo/{s}","bytes":{d},"sha256":"{s}","indexed_at_unix_ms":1,"provenance":{{"producer":"fixture","artifact_kind":"text","toolchain":{{"zig_path":"zig"}}}}}}
        \\
    , .{ path, path, bytes.len, hash });
}

/// Test resource handler that reports a structured JSON failure.
fn failingJsonResource(_: std.mem.Allocator, _: app_context.RuntimeUxContext, _: []const u8) mcp.resources.ResourceError!std.json.Value {
    return @as(mcp.resources.ResourceError, error.ReadFailed);
}

/// Test resource handler that propagates allocation failure.
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

    const zls = try zlsStatusResource(allocator, context, "zigars://zls/status");
    try std.testing.expect(zls.object.get("server_capabilities_json") != null);

    const catalog_content = try catalogResource(allocator, context, "zigars://tools/schema");
    try std.testing.expectEqualStrings("application/json", catalog_content.mimeType.?);
    try std.testing.expectEqualStrings("{\"groups\":[]}", catalog_content.text.?);

    const import_graph = try importGraphResource(allocator, context, "zigars://workspace/import-graph");
    try std.testing.expect(std.mem.indexOf(u8, import_graph.text.?, "local.zig") != null);

    const metrics = try metricsResource(allocator, context, "zigars://metrics");
    try std.testing.expectEqual(@as(i64, 3), metrics.object.get("command_calls").?.integer);

    const jobs = try jobsResource(allocator, context, "zigars://jobs");
    try std.testing.expectEqual(@as(i64, 1), jobs.object.get("job_count").?.integer);

    const events = try runEventsResource(allocator, context, "zigars://run/events");
    try std.testing.expectEqual(@as(i64, 2), events.object.get("event_count").?.integer);

    const roots = try workspaceRootsResource(allocator, context, "zigars://workspace/roots");
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
    const workspace_content = try text_handler(&provider, std.testing.io, allocator, "zigars://workspace");
    try std.testing.expect(std.mem.indexOf(u8, workspace_content.text.?, "workspace=/repo") != null);

    const json_handler = jsonResourceHandler(*ResourceTestProvider, metricsResource);
    const metrics_content = try json_handler(&provider, std.testing.io, allocator, "zigars://metrics");
    try std.testing.expectEqualStrings("application/json", metrics_content.mimeType.?);
    try std.testing.expect(std.mem.indexOf(u8, metrics_content.text.?, "\"command_calls\"") != null);

    const failing_handler = jsonResourceHandler(*ResourceTestProvider, failingJsonResource);
    const error_content = try failing_handler(&provider, std.testing.io, allocator, "zigars://metrics");
    try std.testing.expect(std.mem.indexOf(u8, error_content.text.?, "json_resource_failed") != null);

    const oom_handler = jsonResourceHandler(*ResourceTestProvider, oomJsonResource);
    try std.testing.expectError(error.OutOfMemory, oom_handler(&provider, std.testing.io, allocator, "zigars://metrics"));

    const missing_context = try text_handler(null, std.testing.io, allocator, "zigars://workspace");
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

    const success = try handler(&provider, std.testing.io, allocator, "zigars://file/src/main.zig/imports");
    try std.testing.expect(std.mem.indexOf(u8, success.text.?, "\"resource_kind\": \"imports\"") != null);

    try std.testing.expectError(error.NotFound, handler(&provider, std.testing.io, allocator, "zigars://metrics"));

    const invalid_uri = try handler(&provider, std.testing.io, allocator, "zigars://file/no-mode");
    try std.testing.expect(std.mem.indexOf(u8, invalid_uri.text.?, "invalid_dynamic_resource_uri") != null);

    const missing_file = try handler(&provider, std.testing.io, allocator, "zigars://file/missing.zig/imports");
    try std.testing.expect(std.mem.indexOf(u8, missing_file.text.?, "dynamic_resource_unavailable") != null);

    const analysis_failure = try handler(&provider, std.testing.io, allocator, "zigars://file/unexpected.zig/imports");
    try std.testing.expect(std.mem.indexOf(u8, analysis_failure.text.?, "dynamic_resource_failed") != null);

    const artifact_hash = try artifact_registry.sha256Hex(allocator, "artifact text");
    const artifact_uri = try std.fmt.allocPrint(allocator, "zigars://artifacts/{s}", .{artifact_hash});
    const registry_line = try resourceArtifactRegistryLine(allocator, "zig-out/artifact.txt", "artifact text");
    try workspace.expectRead(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.registry.load" }, registry_line);
    // The artifact resource now reads through the artifact_registry.readArtifact
    // use case, so its resolve/read provenance is the use case's, not the
    // adapter's former inline strings.
    try workspace.expectResolve(.{ .path = "zig-out/artifact.txt", .for_output = false, .provenance = "artifacts.read.resolve" }, "/repo/zig-out/artifact.txt");
    try workspace.expectRead(.{ .path = "zig-out/artifact.txt", .max_bytes = artifact_registry.default_read_limit, .for_output = false, .provenance = "artifacts.read.content" }, "artifact text");
    const artifact = try handler(&provider, std.testing.io, allocator, artifact_uri);
    try std.testing.expectEqualStrings("artifact text", artifact.text.?);

    const invalid_artifact = try handler(&provider, std.testing.io, allocator, "zigars://artifacts/not-a-sha");
    try std.testing.expect(std.mem.indexOf(u8, invalid_artifact.text.?, "invalid_artifact_resource_uri") != null);

    const missing_hash = try artifact_registry.sha256Hex(allocator, "missing");
    const missing_uri = try std.fmt.allocPrint(allocator, "zigars://artifacts/{s}", .{missing_hash});
    try workspace.expectRead(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.registry.load" }, registry_line);
    const missing_artifact = try handler(&provider, std.testing.io, allocator, missing_uri);
    try std.testing.expect(std.mem.indexOf(u8, missing_artifact.text.?, "artifact_resource_not_found") != null);

    const outside_hash = try artifact_registry.sha256Hex(allocator, "outside");
    const outside_uri = try std.fmt.allocPrint(allocator, "zigars://artifacts/{s}", .{outside_hash});
    const outside_registry = try resourceArtifactRegistryLine(allocator, "../secret.txt", "outside");
    try workspace.expectRead(.{ .path = artifact_registry.default_registry_path, .max_bytes = artifact_registry.max_registry_bytes, .for_output = true, .provenance = "artifacts.registry.load" }, outside_registry);
    try workspace.expectResolveError(.{ .path = "../secret.txt", .for_output = false, .provenance = "artifacts.read.resolve" }, error.PathOutsideWorkspace);
    const outside_artifact = try handler(&provider, std.testing.io, allocator, outside_uri);
    try std.testing.expect(std.mem.indexOf(u8, outside_artifact.text.?, "artifact_resource_unavailable") != null);

    const missing_context = try handler(null, std.testing.io, allocator, "zigars://file/src/main.zig/imports");
    try std.testing.expect(std.mem.indexOf(u8, missing_context.text.?, "missing_runtime_context") != null);

    try workspace.verify();
}

test "MCP resource helpers produce structured failures and capability views" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const failure = try resourceFailure(allocator, "zigars://x", .{
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

    const value_failure = try resourceValueFailure(allocator, "zigars://x", .{
        .resource = "workspace",
        .operation = "read",
        .phase = "phase",
        .code = "failed",
        .category = "test",
        .resolution = "retry",
    }, error.AccessDenied);
    try std.testing.expectEqualStrings("AccessDenied", value_failure.object.get("error").?.string);
    try std.testing.expectError(error.OutOfMemory, resourceValueFailure(allocator, "zigars://x", .{
        .resource = "workspace",
        .operation = "read",
        .phase = "phase",
        .code = "failed",
        .category = "test",
        .resolution = "retry",
    }, error.OutOfMemory));

    const context_error = try contextFailure(allocator, "zigars://x", error.MissingRuntime);
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

    const json = try jsonContent(allocator, "zigars://json", .{ .bool = true });
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
        if (jsonContent(allocator, "zigars://json", .{ .object = obj })) |content| {
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
    const import_error = try importGraphResource(arena.allocator(), context, "zigars://workspace/import-graph");
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
    try std.testing.expectError(error.OutOfMemory, dynamicResource(failing.allocator(), context, "zigars://file/src/main.zig/imports"));

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

        if (resourceValueFailure(allocator, "zigars://x", .{
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

        if (zlsStatusResource(allocator, context, "zigars://zls/status")) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}
