//! Projects bootstrap-owned runtime state into the app-facing context contract.
const std = @import("std");
const builtin = @import("builtin");

const app_context = @import("../app/context.zig");
const runtime_mod = @import("runtime_state.zig");

/// Runtime field category used to audit bootstrap/app ownership boundaries.
pub const RuntimeFieldConcern = enum {
    bootstrap,
    app_context,
    infra_state,
    counter,
    cache_state,
};

/// Inventory tracks runtime ownership boundaries during migration from direct runtime access to typed ports.
pub const RuntimeFieldRecord = struct {
    name: []const u8,
    concern: RuntimeFieldConcern,
    migration_note: []const u8,
};

/// Static inventory of runtime fields and their migration ownership notes.
pub const runtime_field_inventory = [_]RuntimeFieldRecord{
    .{ .name = "allocator", .concern = .bootstrap, .migration_note = "owned by process bootstrap; app use cases receive allocator parameters explicitly" },
    .{ .name = "io", .concern = .bootstrap, .migration_note = "owned by startup and concrete infra adapters, not app use cases" },
    .{ .name = "logger", .concern = .bootstrap, .migration_note = "startup/infra logging concern; app code uses observability ports" },
    .{ .name = "config", .concern = .app_context, .migration_note = "tool paths, timeouts, transport, and read-only HTTP endpoint settings project into app context" },
    .{ .name = "workspace", .concern = .app_context, .migration_note = "workspace roots project into app context; concrete workspace IO moves behind WorkspaceStore" },
    .{ .name = "zls_slots", .concern = .bootstrap, .migration_note = "startup lifecycle slots for the infra-owned ZLS session state" },
    .{ .name = "zls", .concern = .infra_state, .migration_note = "infra-owned ZLS lifecycle state projected into app context through read-only snapshots and ZlsGateway" },
    .{ .name = "command_calls", .concern = .counter, .migration_note = "runtime counter projected for metrics; app code should prefer ObservabilitySink events" },
    .{ .name = "zls_requests", .concern = .counter, .migration_note = "runtime counter projected for metrics; app code should prefer ZlsGateway and ObservabilitySink events" },
    .{ .name = "tool_errors", .concern = .counter, .migration_note = "runtime counter projected for public metrics" },
    .{ .name = "backend_probe_cache", .concern = .cache_state, .migration_note = "optional backend cache; app context exposes cache status only" },
    .{ .name = "analysis_cache", .concern = .cache_state, .migration_note = "static-analysis cache exposed through typed StaticCache ports" },
    .{ .name = "semantic_index_cache", .concern = .cache_state, .migration_note = "semantic-index cache exposed through typed StaticCache ports" },
    .{ .name = "observability", .concern = .infra_state, .migration_note = "concrete metrics state; migrated code should use ObservabilitySink" },
    .{ .name = "runtime_ux", .concern = .bootstrap, .migration_note = "server task/job state remains runtime/bootstrap state" },
    .{ .name = "protocol_client", .concern = .bootstrap, .migration_note = "per-call MCP protocol helper port injected by the server adapter and projected into app context" },
    .{ .name = "active_cancellation", .concern = .bootstrap, .migration_note = "per-call cooperative cancellation token projected into infra ports during active MCP dispatch" },
    .{ .name = "temp_counter", .concern = .infra_state, .migration_note = "temporary id state; app code should use ClockAndIds" },
};

/// Looks up the ownership concern for a runtime field name.
pub fn runtimeFieldConcern(name: []const u8) ?RuntimeFieldConcern {
    for (runtime_field_inventory) |record| {
        if (std.mem.eql(u8, record.name, name)) return record.concern;
    }
    return null;
}

/// Snapshots process/runtime state into an app-facing Context plus the supplied port bindings.
/// The returned Context borrows string slices from runtime; it must not outlive the active call.
pub fn fromRuntime(runtime: *runtime_mod.App, port_bindings: app_context.PortSet) app_context.Context {
    // String fields (roots, paths, status) are borrowed directly from the runtime.
    // Counter pointers are passed as mutable references so the Context can increment them.
    return .{
        .workspace = .{
            .root = runtime.workspace.root,
            .cache_root = runtime.workspace.cache_root,
            .transport = switch (runtime.config.transport) {
                .stdio => "stdio",
                .http => "http",
            },
            .host = runtime.config.host,
            .port = runtime.config.port,
        },
        .tool_paths = .{
            .zig = runtime.config.zig_path,
            .zls = runtime.config.zls_path,
            .zlint = runtime.config.zlint_path,
            .zwanzig = runtime.config.zwanzig_path,
            .zflame = runtime.config.zflame_path,
            .diff_folded = runtime.config.diff_folded_path,
        },
        .timeouts = .{
            .command_ms = runtime.config.timeout_ms,
            .zls_ms = runtime.config.zls_timeout_ms,
        },
        .audit_log = .{
            .enabled = runtime.config.audit_log_path != null,
            .mode = if (runtime.config.audit_log_path != null) runtime.config.audit_log_mode.text() else "disabled",
            .path = runtime.config.audit_log_path,
        },
        .platform = .{
            .os = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
            .is_windows = builtin.os.tag == .windows,
            .is_linux = builtin.os.tag == .linux,
        },
        .zls_state = .{
            .status = runtime.zls.status,
            .initialize_response = runtime.zls.initialize_response,
            .last_failure = runtime.zls.last_failure,
            .restart_attempts = runtime.zls.restart_attempts,
            .running = runtime.zls.running(),
        },
        .ports = port_bindings,
        .counters = .{
            .command_calls = &runtime.command_calls,
            .zls_requests = &runtime.zls_requests,
            .tool_errors = &runtime.tool_errors,
        },
        .caches = .{
            .backend_probe = .{
                .zig = runtime.backend_probe_cache.zig != null,
                .zls = runtime.backend_probe_cache.zls != null,
                .zlint = runtime.backend_probe_cache.zlint != null,
                .zwanzig = runtime.backend_probe_cache.zwanzig != null,
                .zflame = runtime.backend_probe_cache.zflame != null,
                .diff_folded = runtime.backend_probe_cache.diff_folded != null,
            },
            .analysis = .{
                .cached = runtime.analysis_cache.index_json != null,
                .signature = runtime.analysis_cache.signature,
                .hits = runtime.analysis_cache.hits,
                .refreshes = runtime.analysis_cache.refreshes,
                .bytes = if (runtime.analysis_cache.index_json) |bytes| bytes.len else 0,
            },
            .semantic_index = .{
                .cached = runtime.semantic_index_cache.index_json != null,
                .signature = runtime.semantic_index_cache.signature,
                .hits = runtime.semantic_index_cache.hits,
                .refreshes = runtime.semantic_index_cache.refreshes,
                .bytes = if (runtime.semantic_index_cache.index_json) |bytes| bytes.len else 0,
            },
        },
        .profiling_probe_cache = .{
            .zflame = probeSnapshot(runtime.backend_probe_cache.zflame),
            .diff_folded = probeSnapshot(runtime.backend_probe_cache.diff_folded),
        },
        .trust_probe_cache = .{
            .zig = probeSnapshot(runtime.backend_probe_cache.zig),
            .zls = probeSnapshot(runtime.backend_probe_cache.zls),
            .zlint = probeSnapshot(runtime.backend_probe_cache.zlint),
            .zwanzig = probeSnapshot(runtime.backend_probe_cache.zwanzig),
            .zflame = probeSnapshot(runtime.backend_probe_cache.zflame),
            .diff_folded = probeSnapshot(runtime.backend_probe_cache.diff_folded),
        },
    };
}

/// Probe snapshots prevent app consumers from observing mutable backend probe internals directly.
fn probeSnapshot(probe: anytype) app_context.CachedBackendProbe {
    // Keep this logic centralized so callers observe one consistent behavior path.
    if (probe) |value| return .{
        .probed = true,
        .ok = value.ok,
        .status = value.status,
        .resolution = value.resolution,
    };
    return .{};
}
