//! Observability MCP adapters that project in-process counters and bounded rings
//! into stable JSON read models.
const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const ports = @import("../../../app/ports.zig");
const read_model = @import("../../../app/usecases/observability/workflows.zig");
const mcp_result = @import("../result.zig");
const values = @import("runtime_metrics_values.zig");

/// Returns the full metrics v2 object assembled from runtime counters.
pub fn zigarsMetricsV2(
    allocator: std.mem.Allocator,
    context: app_context.ObservabilityContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const report = read_model.metricsReport(scratch, context) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, metricsV2Value(scratch, report) catch return error.OutOfMemory);
}

/// Returns backend probe history recorded by the current server process.
pub fn zigarsBackendHealthHistory(
    allocator: std.mem.Allocator,
    context: app_context.ObservabilityContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const report = read_model.metricsReport(scratch, context) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, backendHistoryValue(scratch, report) catch return error.OutOfMemory);
}

/// Returns ZLS lifecycle events recorded by the current server process.
pub fn zigarsZlsTimeline(
    allocator: std.mem.Allocator,
    context: app_context.ObservabilityContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const report = read_model.metricsReport(scratch, context) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, zlsTimelineValue(scratch, report) catch return error.OutOfMemory);
}

/// Returns observed MCP tool latency and error counters.
pub fn zigarsToolLatency(
    allocator: std.mem.Allocator,
    context: app_context.ObservabilityContext,
    _: ?std.json.Value,
) mcp.tools.ToolError!mcp.tools.ToolResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const report = read_model.metricsReport(scratch, context) catch return error.OutOfMemory;
    return mcp_result.structured(allocator, toolLatencyValue(scratch, report.observed) catch return error.OutOfMemory);
}

/// Builds the top-level zigars_metrics_v2 JSON object.
fn metricsV2Value(allocator: std.mem.Allocator, report: read_model.MetricsReport) !std.json.Value {
    const base = report.base;
    const observed = report.observed;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_metrics_v2" });
    try obj.put(allocator, "schema_version", .{ .integer = 2 });
    try obj.put(allocator, "ok", .{ .bool = true });
    try obj.put(allocator, "evidence_source", .{ .string = "runtime_counters_and_bounded_observability_rings" });
    try obj.put(allocator, "workspace", .{ .string = base.workspace });
    try obj.put(allocator, "command_calls", .{ .integer = @intCast(base.command_calls) });
    try obj.put(allocator, "zls_requests", .{ .integer = @intCast(base.zls_requests) });
    try obj.put(allocator, "runtime_tool_errors", .{ .integer = @intCast(base.tool_errors) });
    try obj.put(allocator, "observed_tool_calls", .{ .integer = @intCast(observed.total_tool_calls) });
    try obj.put(allocator, "observed_tool_errors", .{ .integer = @intCast(observed.total_tool_errors) });
    try obj.put(allocator, "observed_tool_error_rate_per_1000", .{ .integer = @intCast(values.ratePerThousand(observed.total_tool_errors, observed.total_tool_calls)) });
    try obj.put(allocator, "observed_mcp_requests", .{ .integer = @intCast(observed.total_mcp_requests) });
    try obj.put(allocator, "observed_mcp_request_errors", .{ .integer = @intCast(observed.total_mcp_request_errors) });
    try obj.put(allocator, "analysis_cache", try analysisCacheValue(allocator, base.analysis_cache));
    try obj.put(allocator, "artifact_registry", try artifactMetricsValue(allocator, base.artifacts));
    try obj.put(allocator, "zls_status", .{ .string = base.zls_status });
    try obj.put(allocator, "zls_restart_attempts", .{ .integer = @intCast(base.zls_restart_attempts) });
    try obj.put(allocator, "zls_last_failure", optionalString(base.zls_last_failure));
    try obj.put(allocator, "backend_health_history", try backendHistoryValue(allocator, report));
    try obj.put(allocator, "zls_timeline", try zlsTimelineValue(allocator, report));
    try obj.put(allocator, "startup_timings", try startupTimingsValue(allocator, observed));
    try obj.put(allocator, "audit_logging", try auditLoggingValue(allocator, observed));
    try obj.put(allocator, "request_cancellation", try cancellationValue(allocator, observed));
    try obj.put(allocator, "mcp_method_latency", try methodLatencyValue(allocator, observed));
    try obj.put(allocator, "tool_latency", try toolLatencyValue(allocator, observed));
    try obj.put(allocator, "command_durations", try commandDurationsValue(allocator, observed));
    try obj.put(allocator, "limitations", try limitationsValue(allocator));
    return .{ .object = obj };
}

/// Builds backend health history with current probe-cache context.
fn backendHistoryValue(allocator: std.mem.Allocator, report: read_model.MetricsReport) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_backend_health_history" });
    try obj.put(allocator, "history_capacity", .{ .integer = read_model.max_backend_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(report.observed.backend_event_count) });
    try obj.put(allocator, "events", try backendEventsValue(allocator, report.observed));
    try obj.put(allocator, "current_probe_cache", try backendCacheValue(allocator, report.base.backend_probe_cache));
    try obj.put(allocator, "resolution", .{ .string = "Call zigars_doctor with probe_backends=true to refresh optional backend health; this history records probes observed in the current server process." });
    return .{ .object = obj };
}

/// Builds a monotonic ZLS event timeline and current status snapshot.
fn zlsTimelineValue(allocator: std.mem.Allocator, report: read_model.MetricsReport) !std.json.Value {
    const base = report.base;
    const observed = report.observed;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_zls_timeline" });
    try obj.put(allocator, "history_capacity", .{ .integer = read_model.max_zls_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(observed.zls_event_count) });
    try obj.put(allocator, "current_status", .{ .string = base.zls_status });
    try obj.put(allocator, "current_failure", optionalString(base.zls_last_failure));
    try obj.put(allocator, "restart_attempts", .{ .integer = @intCast(base.zls_restart_attempts) });
    try obj.put(allocator, "events", try zlsEventsValue(allocator, observed, base));
    try obj.put(allocator, "timeline_clock", .{ .string = "monotonic_sequence" });
    return .{ .object = obj };
}

/// Builds tool latency counters in milliseconds.
fn toolLatencyValue(allocator: std.mem.Allocator, snapshot: ports.ObservabilitySnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_tool_latency" });
    try obj.put(allocator, "observed_tool_calls", .{ .integer = @intCast(snapshot.total_tool_calls) });
    try obj.put(allocator, "observed_tool_errors", .{ .integer = @intCast(snapshot.total_tool_errors) });
    try obj.put(allocator, "tool_count", .{ .integer = @intCast(snapshot.tool_stats.len) });
    try obj.put(allocator, "tools", try values.toolStatsValue(allocator, snapshot.tool_stats));
    try obj.put(allocator, "correlation_history_capacity", .{ .integer = read_model.max_tool_call_correlations });
    try obj.put(allocator, "recorded_correlations", .{ .integer = @intCast(snapshot.tool_call_correlation_count) });
    try obj.put(allocator, "recent_tool_call_correlations", try values.toolCallCorrelationsValue(allocator, snapshot.tool_call_correlations));
    try obj.put(allocator, "units", .{ .string = "milliseconds" });
    try obj.put(allocator, "resolution", .{ .string = "Latency is measured around MCP schema validation and handler dispatch inside the current zigars process." });
    return .{ .object = obj };
}

/// Builds MCP request method latency counters in milliseconds.
fn methodLatencyValue(allocator: std.mem.Allocator, snapshot: ports.ObservabilitySnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_mcp_method_latency" });
    try obj.put(allocator, "observed_mcp_requests", .{ .integer = @intCast(snapshot.total_mcp_requests) });
    try obj.put(allocator, "observed_mcp_request_errors", .{ .integer = @intCast(snapshot.total_mcp_request_errors) });
    try obj.put(allocator, "method_count", .{ .integer = @intCast(snapshot.method_stats.len) });
    try obj.put(allocator, "methods", try values.methodStatsValue(allocator, snapshot.method_stats));
    try obj.put(allocator, "units", .{ .string = "milliseconds" });
    try obj.put(allocator, "resolution", .{ .string = "Request method latency is measured inside the current zigars process and resets on restart." });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for command durations.
fn commandDurationsValue(allocator: std.mem.Allocator, snapshot: ports.ObservabilitySnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_command_durations" });
    try obj.put(allocator, "history_capacity", .{ .integer = read_model.max_command_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(snapshot.command_event_count) });
    try obj.put(allocator, "avg_duration_ms", .{ .integer = @intCast(if (snapshot.command_event_count == 0) 0 else snapshot.total_command_duration_ms / snapshot.command_event_count) });
    try obj.put(allocator, "latency_percentiles", try values.latencyPercentilesValue(allocator, snapshot.command_latency_samples, snapshot.command_latency_sample_count));
    try obj.put(allocator, "events", try commandEventsValue(allocator, snapshot.command_events));
    try obj.put(allocator, "resolution", .{ .string = "Command durations are observed for commands routed through shared zigars command helpers in the current server process." });
    return .{ .object = obj };
}

/// Builds process-local startup phase timings.
fn startupTimingsValue(allocator: std.mem.Allocator, snapshot: ports.ObservabilitySnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_startup_timings" });
    try obj.put(allocator, "clock", .{ .string = "monotonic_awake" });
    try obj.put(allocator, "history_capacity", .{ .integer = read_model.max_startup_phases });
    try obj.put(allocator, "recorded_phases", .{ .integer = @intCast(snapshot.startup_phase_count) });
    try obj.put(allocator, "phases", try startupPhasesValue(allocator, snapshot.startup_phases));
    try obj.put(allocator, "resolution", .{ .string = "Startup timings are process-local, runtime-specific, and reset when zigars restarts." });
    return .{ .object = obj };
}

/// Builds audit logging runtime state.
fn auditLoggingValue(allocator: std.mem.Allocator, snapshot: ports.ObservabilitySnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_audit_logging" });
    try obj.put(allocator, "enabled", .{ .bool = snapshot.audit_enabled });
    try obj.put(allocator, "mode", .{ .string = snapshot.audit_mode });
    try obj.put(allocator, "path", optionalString(snapshot.audit_path));
    try obj.put(allocator, "records_written", .{ .integer = @intCast(snapshot.audit_records_written) });
    try obj.put(allocator, "write_errors", .{ .integer = @intCast(snapshot.audit_write_errors) });
    try obj.put(allocator, "last_error", optionalString(snapshot.audit_last_error));
    try obj.put(allocator, "privacy", .{ .string = "Audit logging is opt-in; metadata mode stores sizes and hashes, redacted mode masks secret-looking fields, and full mode records raw MCP payloads only when explicitly configured." });
    return .{ .object = obj };
}

/// Builds request cancellation counters and recent outcomes.
fn cancellationValue(allocator: std.mem.Allocator, snapshot: ports.ObservabilitySnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_request_cancellation" });
    try obj.put(allocator, "requested", .{ .integer = @intCast(snapshot.cancellation_requested) });
    try obj.put(allocator, "unknown", .{ .integer = @intCast(snapshot.cancellation_unknown) });
    try obj.put(allocator, "completed", .{ .integer = @intCast(snapshot.cancellation_completed) });
    try obj.put(allocator, "uncancellable", .{ .integer = @intCast(snapshot.cancellation_uncancellable) });
    try obj.put(allocator, "history_capacity", .{ .integer = read_model.max_cancellation_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(snapshot.cancellation_event_count) });
    try obj.put(allocator, "events", try cancellationEventsValue(allocator, snapshot.cancellation_events));
    try obj.put(allocator, "resolution", .{ .string = "Cancellation is cooperative and process-local; sequential dispatch can observe notifications while the server is reading MCP messages or waiting on helper protocol responses." });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for analysis cache.
fn analysisCacheValue(allocator: std.mem.Allocator, cache: read_model.AnalysisCacheSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "present", .{ .bool = cache.present });
    try obj.put(allocator, "hits", .{ .integer = @intCast(cache.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(cache.refreshes) });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(cache.bytes) });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for artifact metrics.
fn artifactMetricsValue(allocator: std.mem.Allocator, metrics: read_model.ArtifactMetrics) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "registry_available", .{ .bool = metrics.registry_available });
    try obj.put(allocator, "registry_entries", .{ .integer = @intCast(metrics.registry_entries) });
    try obj.put(allocator, "scanned_artifacts", .{ .integer = @intCast(metrics.scanned_artifacts) });
    try obj.put(allocator, "scan_limit", .{ .integer = @intCast(metrics.scan_limit) });
    try obj.put(allocator, "status", .{ .string = metrics.status });
    try obj.put(allocator, "resolution", .{ .string = "Use zigars_artifact_index for artifact paths, hashes, and provenance details." });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for backend events.
fn backendEventsValue(allocator: std.mem.Allocator, snapshot: ports.ObservabilitySnapshot) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (snapshot.backend_events) |event| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "sequence", .{ .integer = @intCast(event.sequence) });
        try obj.put(allocator, "backend", .{ .string = event.backend });
        try obj.put(allocator, "ok", .{ .bool = event.ok });
        try obj.put(allocator, "status", .{ .string = event.status });
        try obj.put(allocator, "resolution", .{ .string = event.resolution });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

/// Returns an allocator-owned JSON value for command events.
fn commandEventsValue(allocator: std.mem.Allocator, events: []const ports.ObservabilityCommandEvent) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (events) |event| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "sequence", .{ .integer = @intCast(event.sequence) });
        try obj.put(allocator, "title", .{ .string = event.title });
        try obj.put(allocator, "argv0", .{ .string = event.argv0 });
        try obj.put(allocator, "duration_ms", .{ .integer = event.duration_ms });
        try obj.put(allocator, "ok", .{ .bool = event.ok });
        try obj.put(allocator, "error", optionalString(event.error_name));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

/// Returns allocator-owned JSON for startup phase timing rows.
fn startupPhasesValue(allocator: std.mem.Allocator, phases: []const ports.ObservabilityStartupPhase) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (phases) |phase| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "sequence", .{ .integer = @intCast(phase.sequence) });
        try obj.put(allocator, "name", .{ .string = phase.name });
        try obj.put(allocator, "start_ms", .{ .integer = @intCast(phase.start_ms) });
        try obj.put(allocator, "duration_ms", .{ .integer = @intCast(phase.duration_ms) });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

/// Returns allocator-owned JSON for cancellation outcome rows.
fn cancellationEventsValue(allocator: std.mem.Allocator, events: []const ports.ObservabilityCancellationEvent) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (events) |*event| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "sequence", .{ .integer = @intCast(event.sequence) });
        try obj.put(allocator, "status", .{ .string = event.status });
        try obj.put(allocator, "mcp_request_id", try cancellationRequestIdValue(allocator, event));
        try obj.put(allocator, "method", .{ .string = event.methodSlice() });
        try obj.put(allocator, "method_truncated", .{ .bool = event.method_truncated });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

/// Returns allocator-owned JSON for one cancellation request id.
fn cancellationRequestIdValue(allocator: std.mem.Allocator, event: *const ports.ObservabilityCancellationEvent) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "type", .{ .string = event.mcp_request_id_type });
    try obj.put(allocator, "value", if (event.requestIdValue()) |value| .{ .string = value } else .null);
    try obj.put(allocator, "truncated", .{ .bool = event.mcp_request_id_truncated });
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for ZLS events.
fn zlsEventsValue(
    allocator: std.mem.Allocator,
    snapshot: ports.ObservabilitySnapshot,
    base: read_model.BaseMetrics,
) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    if (snapshot.zls_event_count == 0) {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "sequence", .{ .integer = 0 });
        try obj.put(allocator, "status", .{ .string = base.zls_status });
        try obj.put(allocator, "failure", optionalString(base.zls_last_failure));
        try obj.put(allocator, "restart_attempts", .{ .integer = @intCast(base.zls_restart_attempts) });
        try obj.put(allocator, "source", .{ .string = "current_snapshot" });
        try array.append(.{ .object = obj });
        return .{ .array = array };
    }

    for (snapshot.zls_events) |event| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "sequence", .{ .integer = @intCast(event.sequence) });
        try obj.put(allocator, "status", .{ .string = event.status });
        try obj.put(allocator, "failure", optionalString(event.failure));
        try obj.put(allocator, "restart_attempts", .{ .integer = @intCast(event.restart_attempts) });
        try obj.put(allocator, "source", .{ .string = "runtime_transition" });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

/// Returns an allocator-owned JSON value for backend cache.
fn backendCacheValue(allocator: std.mem.Allocator, cache: read_model.BackendProbeCacheSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig", try probeSnapshotValue(allocator, cache.zig));
    try obj.put(allocator, "zls", try probeSnapshotValue(allocator, cache.zls));
    try obj.put(allocator, "zwanzig", try probeSnapshotValue(allocator, cache.zwanzig));
    try obj.put(allocator, "zflame", try probeSnapshotValue(allocator, cache.zflame));
    try obj.put(allocator, "diff_folded", try probeSnapshotValue(allocator, cache.diff_folded));
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for probe snapshot.
fn probeSnapshotValue(allocator: std.mem.Allocator, probe: ?read_model.ProbeSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    if (probe) |p| {
        try obj.put(allocator, "probed", .{ .bool = true });
        try obj.put(allocator, "ok", .{ .bool = p.ok });
        try obj.put(allocator, "status", .{ .string = p.status });
        try obj.put(allocator, "resolution", .{ .string = p.resolution });
    } else {
        try obj.put(allocator, "probed", .{ .bool = false });
        try obj.put(allocator, "ok", .null);
        try obj.put(allocator, "status", .{ .string = "not probed" });
        try obj.put(allocator, "resolution", .{ .string = "No backend probe has been recorded in this process." });
    }
    return .{ .object = obj };
}

/// Returns an allocator-owned JSON value for limitations.
fn limitationsValue(allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    try array.append(.{ .string = "In-memory metrics reset when the zigars process restarts." });
    try array.append(.{ .string = "Backend history records probes observed through shared probe helpers, not external backend state changes." });
    try array.append(.{ .string = "Command-duration history covers commands routed through shared zigars helpers; direct external process state is not inferred." });
    try array.append(.{ .string = "Latency is dispatch duration and does not include client/network serialization time." });
    try array.append(.{ .string = "Percentiles are computed from bounded process-local samples and are withheld until enough samples are retained." });
    try array.append(.{ .string = "Startup timings and cancellation counters are process-local and runtime-specific." });
    return .{ .array = array };
}

/// Converts an optional string to an allocator-owned JSON string or null.
fn optionalString(value: ?[]const u8) std.json.Value {
    return if (value) |text| .{ .string = text } else .null;
}

test "runtime metrics value builders release partial objects on allocation failure" {
    const Fixture = struct {
        var tool_stats = [_]ports.ObservabilityToolStats{
            .{ .name = "zig_check", .calls = 2, .errors = 1, .total_latency_ms = 12, .max_latency_ms = 8, .last_latency_ms = 4, .last_error = true },
        };
        var backend_events = [_]ports.ObservabilityBackendEvent{
            .{ .sequence = 1, .backend = "zig", .ok = true, .status = "ok", .resolution = "backend command completed" },
        };
        var zls_events = [_]ports.ObservabilityZlsEvent{
            .{ .sequence = 2, .status = "failed", .failure = "FileNotFound", .restart_attempts = 1 },
        };
        var command_events = [_]ports.ObservabilityCommandEvent{
            .{ .sequence = 3, .title = "zig build", .argv0 = "zig", .duration_ms = 15, .ok = false, .error_name = "BuildFailed" },
        };

        /// Test stub that returns a runtime metrics snapshot.
        fn snapshot() ports.ObservabilitySnapshot {
            return .{
                .tool_stats = tool_stats[0..],
                .backend_events = backend_events[0..],
                .zls_events = zls_events[0..],
                .command_events = command_events[0..],
                .total_tool_calls = 2,
                .total_tool_errors = 1,
                .total_command_duration_ms = 15,
                .command_event_count = 1,
                .backend_event_count = 1,
                .zls_event_count = 1,
            };
        }

        /// Test stub that returns a runtime metrics report.
        fn report() read_model.MetricsReport {
            return .{
                .base = .{
                    .workspace = "/workspace",
                    .command_calls = 4,
                    .zls_requests = 5,
                    .tool_errors = 1,
                    .zls_status = "failed",
                    .zls_last_failure = "FileNotFound",
                    .zls_restart_attempts = 2,
                    .backend_probe_cache = .{
                        .zig = .{ .ok = true, .status = "ok", .resolution = "backend command completed" },
                    },
                    .analysis_cache = .{ .present = true, .hits = 1, .refreshes = 2, .bytes = 3 },
                    .artifacts = .{ .registry_available = true, .registry_entries = 1, .scanned_artifacts = 2, .scan_limit = 3, .status = "ok" },
                },
                .observed = snapshot(),
            };
        }
    };

    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        const report = Fixture.report();
        const snapshot = Fixture.snapshot();

        if (metricsV2Value(allocator, report)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        if (backendHistoryValue(allocator, report)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        if (zlsTimelineValue(allocator, report)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        if (toolLatencyValue(allocator, snapshot)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        if (values.toolCallCorrelationsValue(allocator, snapshot.tool_call_correlations)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        if (commandDurationsValue(allocator, snapshot)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        if (zlsEventsValue(allocator, .{}, report.base)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        if (backendCacheValue(allocator, report.base.backend_probe_cache)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        if (limitationsValue(allocator)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
    }
}
