//! JSON value builders for the zigars_metrics_v2 MCP response.
//! Each public function produces an allocator-owned `std.json.Value`; callers
//! are responsible for freeing the returned object tree.  No output goes to
//! stdout; this module is a pure in-memory value builder.

const std = @import("std");
const state_mod = @import("state.zig");

const State = state_mod.State;
const ToolCallCorrelation = state_mod.ToolCallCorrelation;
const CancellationEvent = state_mod.CancellationEvent;
const LatencySamples = state_mod.LatencySamples;

/// Caller-supplied context that is not stored in `State` (workspace path, ZLS
/// current status, cache snapshots, artifact counts).  Passed alongside `State`
/// to every render function that needs live application-layer data.
pub const BaseMetrics = struct {
    workspace: []const u8,
    command_calls: usize,
    zls_requests: usize,
    tool_errors: usize,
    zls_status: []const u8,
    zls_last_failure: ?[]const u8,
    zls_restart_attempts: usize,
    backend_probe_cache: BackendProbeCacheSnapshot,
    analysis_cache: AnalysisCacheSnapshot,
    artifacts: ArtifactMetrics,
};

/// Point-in-time snapshot of static-analysis cache counters for inclusion in the
/// metrics response; sourced from the application cache, not from `State`.
pub const AnalysisCacheSnapshot = struct {
    present: bool = false,
    hits: usize = 0,
    refreshes: usize = 0,
    bytes: usize = 0,
};

/// Point-in-time artifact registry counters for inclusion in the metrics
/// response; sourced from the artifact registry port, not from `State`.
pub const ArtifactMetrics = struct {
    registry_available: bool = false,
    registry_entries: usize = 0,
    scanned_artifacts: usize = 0,
    scan_limit: usize = 0,
    status: []const u8 = "not_scanned",
};

/// Most-recently observed probe results for each optional backend, keyed by
/// backend name.  Null means the backend has not been probed in this process.
pub const BackendProbeCacheSnapshot = struct {
    zig: ?ProbeSnapshot = null,
    zls: ?ProbeSnapshot = null,
    zwanzig: ?ProbeSnapshot = null,
    zflame: ?ProbeSnapshot = null,
    diff_folded: ?ProbeSnapshot = null,
};

/// Result of a single backend availability probe.
pub const ProbeSnapshot = struct {
    ok: bool,
    status: []const u8,
    resolution: []const u8,
};

/// Builds the top-level zigars_metrics_v2 JSON object from process state and
/// caller-supplied base metrics.  Caller owns the returned value and must free
/// all nested ObjectMaps and Arrays through its own cleanup or an arena.
pub fn metricsV2Value(allocator: std.mem.Allocator, state: *const State, base: BaseMetrics) !std.json.Value {
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
    try obj.put(allocator, "observed_tool_calls", .{ .integer = @intCast(state.total_tool_calls) });
    try obj.put(allocator, "observed_tool_errors", .{ .integer = @intCast(state.total_tool_errors) });
    try obj.put(allocator, "observed_tool_error_rate_per_1000", .{ .integer = @intCast(ratePerThousand(state.total_tool_errors, state.total_tool_calls)) });
    try obj.put(allocator, "observed_mcp_requests", .{ .integer = @intCast(state.total_mcp_requests) });
    try obj.put(allocator, "observed_mcp_request_errors", .{ .integer = @intCast(state.total_mcp_request_errors) });
    try obj.put(allocator, "analysis_cache", try analysisCacheValue(allocator, base.analysis_cache));
    try obj.put(allocator, "artifact_registry", try artifactMetricsValue(allocator, base.artifacts));
    try obj.put(allocator, "zls_status", .{ .string = base.zls_status });
    try obj.put(allocator, "zls_restart_attempts", .{ .integer = @intCast(base.zls_restart_attempts) });
    try obj.put(allocator, "zls_last_failure", optionalString(base.zls_last_failure));
    try obj.put(allocator, "backend_health_history", try backendHistoryValue(allocator, state, base));
    try obj.put(allocator, "zls_timeline", try zlsTimelineValue(allocator, state, base));
    try obj.put(allocator, "startup_timings", try startupTimingsValue(allocator, state));
    try obj.put(allocator, "audit_logging", try auditLoggingValue(allocator, state));
    try obj.put(allocator, "request_cancellation", try cancellationValue(allocator, state));
    try obj.put(allocator, "mcp_method_latency", try methodLatencyValue(allocator, state));
    try obj.put(allocator, "tool_latency", try toolLatencyValue(allocator, state));
    try obj.put(allocator, "command_durations", try commandDurationsValue(allocator, state));
    try obj.put(allocator, "retention", try retentionValue(allocator, state));
    try obj.put(allocator, "limitations", try limitationsValue(allocator));
    return .{ .object = obj };
}

/// Builds the zigars_backend_health_history section: bounded probe event ring
/// plus the current cached probe results for each known backend.
pub fn backendHistoryValue(allocator: std.mem.Allocator, state: *const State, base: BaseMetrics) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_backend_health_history" });
    try obj.put(allocator, "history_capacity", .{ .integer = state_mod.max_backend_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(state.backend_event_count) });
    try obj.put(allocator, "events", try backendEventsValue(allocator, state));
    try obj.put(allocator, "current_probe_cache", try backendProbeCacheValue(allocator, base.backend_probe_cache));
    try obj.put(allocator, "resolution", .{ .string = "Call zigars_doctor with probe_backends=true to refresh optional backend health; this history records probes observed in the current server process." });
    return .{ .object = obj };
}

/// Builds the zigars_zls_timeline section: deduped ZLS status transition ring
/// plus the current status from `base`.  When the ring is empty, a synthetic
/// sequence-0 event is injected from the current base snapshot.
pub fn zlsTimelineValue(allocator: std.mem.Allocator, state: *const State, base: BaseMetrics) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_zls_timeline" });
    try obj.put(allocator, "history_capacity", .{ .integer = state_mod.max_zls_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(state.zls_event_count) });
    try obj.put(allocator, "current_status", .{ .string = base.zls_status });
    try obj.put(allocator, "current_failure", optionalString(base.zls_last_failure));
    try obj.put(allocator, "restart_attempts", .{ .integer = @intCast(base.zls_restart_attempts) });
    try obj.put(allocator, "events", try zlsEventsValue(allocator, state, base));
    try obj.put(allocator, "timeline_clock", .{ .string = "monotonic_sequence" });
    return .{ .object = obj };
}

/// Builds the zigars_tool_latency section: per-tool call/error counters,
/// latency percentiles, and the recent tool-call correlation ring.
pub fn toolLatencyValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_tool_latency" });
    try obj.put(allocator, "observed_tool_calls", .{ .integer = @intCast(state.total_tool_calls) });
    try obj.put(allocator, "observed_tool_errors", .{ .integer = @intCast(state.total_tool_errors) });
    try obj.put(allocator, "tool_stat_capacity", .{ .integer = state_mod.max_tool_stats });
    try obj.put(allocator, "tool_count", .{ .integer = @intCast(state.tool_stat_count) });
    try obj.put(allocator, "dropped_tool_stat_observations", .{ .integer = @intCast(state.dropped_tool_stat_observations) });
    try obj.put(allocator, "tools", try toolStatsValue(allocator, state));
    try obj.put(allocator, "correlation_history_capacity", .{ .integer = state_mod.max_tool_call_correlations });
    try obj.put(allocator, "recorded_correlations", .{ .integer = @intCast(state.tool_call_correlation_count) });
    try obj.put(allocator, "truncated_request_id_values", .{ .integer = @intCast(state.truncated_tool_call_request_ids) });
    try obj.put(allocator, "truncated_tool_call_ids", .{ .integer = @intCast(state.truncated_tool_call_ids) });
    try obj.put(allocator, "recent_tool_call_correlations", try toolCallCorrelationsValue(allocator, state));
    try obj.put(allocator, "units", .{ .string = "milliseconds" });
    try obj.put(allocator, "resolution", .{ .string = "Latency is measured around MCP schema validation and handler dispatch inside the current zigars process." });
    return .{ .object = obj };
}

/// Builds the zigars_mcp_method_latency section: per-MCP-method request
/// counters and latency percentiles, noting any truncated method names.
pub fn methodLatencyValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_mcp_method_latency" });
    try obj.put(allocator, "observed_mcp_requests", .{ .integer = @intCast(state.total_mcp_requests) });
    try obj.put(allocator, "observed_mcp_request_errors", .{ .integer = @intCast(state.total_mcp_request_errors) });
    try obj.put(allocator, "method_stat_capacity", .{ .integer = state_mod.max_method_stats });
    try obj.put(allocator, "method_count", .{ .integer = @intCast(state.method_stat_count) });
    try obj.put(allocator, "dropped_method_stat_observations", .{ .integer = @intCast(state.dropped_method_stat_observations) });
    try obj.put(allocator, "truncated_method_names", .{ .integer = @intCast(state.truncated_method_names) });
    try obj.put(allocator, "methods", try methodStatsValue(allocator, state));
    try obj.put(allocator, "units", .{ .string = "milliseconds" });
    try obj.put(allocator, "resolution", .{ .string = "Request method latency is measured inside the current zigars process and resets on restart." });
    return .{ .object = obj };
}

/// Builds the zigars_command_durations section: bounded subprocess invocation
/// history and aggregate latency percentiles.  Duration unit is milliseconds.
pub fn commandDurationsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_command_durations" });
    try obj.put(allocator, "history_capacity", .{ .integer = state_mod.max_command_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(state.command_event_count) });
    try obj.put(allocator, "avg_duration_ms", .{ .integer = @intCast(if (state.command_event_count == 0) 0 else state.total_command_duration_ms / state.command_event_count) });
    try obj.put(allocator, "latency_percentiles", try latencyPercentilesValue(allocator, state.command_latency));
    try obj.put(allocator, "events", try commandEventsValue(allocator, state));
    try obj.put(allocator, "resolution", .{ .string = "Command durations are observed for commands routed through shared zigars command helpers in the current server process." });
    return .{ .object = obj };
}

/// Builds the zigars_startup_timings section: monotonic-awake-clock phase
/// timings recorded during bootstrap.  Resets when the process restarts.
pub fn startupTimingsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_startup_timings" });
    try obj.put(allocator, "clock", .{ .string = "monotonic_awake" });
    try obj.put(allocator, "history_capacity", .{ .integer = state_mod.max_startup_phases });
    try obj.put(allocator, "recorded_phases", .{ .integer = @intCast(state.startup_phase_count) });
    try obj.put(allocator, "phases", try startupPhasesValue(allocator, state));
    try obj.put(allocator, "resolution", .{ .string = "Startup timings are process-local, runtime-specific, and reset when zigars restarts." });
    return .{ .object = obj };
}

/// Builds the zigars_audit_logging section: enabled flag, current mode and
/// path, write counters, and the privacy notice for the configured mode.
pub fn auditLoggingValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_audit_logging" });
    try obj.put(allocator, "enabled", .{ .bool = state.audit_enabled });
    try obj.put(allocator, "mode", .{ .string = state.audit_mode });
    try obj.put(allocator, "path", optionalString(state.audit_path));
    try obj.put(allocator, "records_written", .{ .integer = @intCast(state.audit_records_written) });
    try obj.put(allocator, "write_errors", .{ .integer = @intCast(state.audit_write_errors) });
    try obj.put(allocator, "last_error", optionalString(state.audit_last_error));
    try obj.put(allocator, "privacy", .{ .string = "Audit logging is opt-in; metadata mode stores sizes and hashes, redacted mode masks secret-looking fields, and full mode records raw MCP payloads only when explicitly configured." });
    return .{ .object = obj };
}

/// Builds the zigars_request_cancellation section: aggregate outcome counters
/// and the bounded cancellation notification event ring.
pub fn cancellationValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_request_cancellation" });
    try obj.put(allocator, "requested", .{ .integer = @intCast(state.cancellation_requested) });
    try obj.put(allocator, "unknown", .{ .integer = @intCast(state.cancellation_unknown) });
    try obj.put(allocator, "completed", .{ .integer = @intCast(state.cancellation_completed) });
    try obj.put(allocator, "uncancellable", .{ .integer = @intCast(state.cancellation_uncancellable) });
    try obj.put(allocator, "history_capacity", .{ .integer = state_mod.max_cancellation_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(state.cancellation_event_count) });
    try obj.put(allocator, "truncated_request_id_values", .{ .integer = @intCast(state.truncated_cancellation_request_ids) });
    try obj.put(allocator, "truncated_methods", .{ .integer = @intCast(state.truncated_cancellation_methods) });
    try obj.put(allocator, "events", try cancellationEventsValue(allocator, state));
    try obj.put(allocator, "resolution", .{ .string = "Cancellation is cooperative and process-local; sequential dispatch can observe notifications while the server is reading MCP messages or waiting on helper protocol responses." });
    return .{ .object = obj };
}

/// Builds the zigars_observability_retention section: capacity constants,
/// current fill counts, and all truncation/drop counters for this process.
pub fn retentionValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_observability_retention" });
    try obj.put(allocator, "tool_stat_capacity", .{ .integer = state_mod.max_tool_stats });
    try obj.put(allocator, "tool_stat_count", .{ .integer = @intCast(state.tool_stat_count) });
    try obj.put(allocator, "dropped_tool_stat_observations", .{ .integer = @intCast(state.dropped_tool_stat_observations) });
    try obj.put(allocator, "method_stat_capacity", .{ .integer = state_mod.max_method_stats });
    try obj.put(allocator, "method_stat_count", .{ .integer = @intCast(state.method_stat_count) });
    try obj.put(allocator, "dropped_method_stat_observations", .{ .integer = @intCast(state.dropped_method_stat_observations) });
    try obj.put(allocator, "truncated_method_names", .{ .integer = @intCast(state.truncated_method_names) });
    try obj.put(allocator, "request_id_value_capacity", .{ .integer = state_mod.max_request_id_value_len });
    try obj.put(allocator, "truncated_tool_call_request_ids", .{ .integer = @intCast(state.truncated_tool_call_request_ids) });
    try obj.put(allocator, "truncated_tool_call_ids", .{ .integer = @intCast(state.truncated_tool_call_ids) });
    try obj.put(allocator, "truncated_cancellation_request_ids", .{ .integer = @intCast(state.truncated_cancellation_request_ids) });
    try obj.put(allocator, "truncated_cancellation_methods", .{ .integer = @intCast(state.truncated_cancellation_methods) });
    return .{ .object = obj };
}

fn analysisCacheValue(allocator: std.mem.Allocator, cache: AnalysisCacheSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "present", .{ .bool = cache.present });
    try obj.put(allocator, "hits", .{ .integer = @intCast(cache.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(cache.refreshes) });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(cache.bytes) });
    return .{ .object = obj };
}

fn artifactMetricsValue(allocator: std.mem.Allocator, metrics: ArtifactMetrics) !std.json.Value {
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

fn toolStatsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (state.tool_stats[0..state.tool_stat_count]) |stat| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "name", .{ .string = stat.name });
        try obj.put(allocator, "calls", .{ .integer = @intCast(stat.calls) });
        try obj.put(allocator, "errors", .{ .integer = @intCast(stat.errors) });
        try obj.put(allocator, "error_rate_per_1000", .{ .integer = @intCast(ratePerThousand(stat.errors, stat.calls)) });
        try obj.put(allocator, "avg_latency_ms", .{ .integer = @intCast(if (stat.calls == 0) 0 else stat.total_latency_ms / stat.calls) });
        try obj.put(allocator, "max_latency_ms", .{ .integer = @intCast(stat.max_latency_ms) });
        try obj.put(allocator, "last_latency_ms", .{ .integer = @intCast(stat.last_latency_ms) });
        try obj.put(allocator, "last_error", .{ .bool = stat.last_error });
        try obj.put(allocator, "latency_samples_retained", .{ .integer = @intCast(stat.latency.retained()) });
        try obj.put(allocator, "latency_percentiles", try latencyPercentilesValue(allocator, stat.latency));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn methodStatsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (state.method_stats[0..state.method_stat_count]) |*stat| {
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "name", .{ .string = stat.nameSlice() });
        try obj.put(allocator, "name_truncated", .{ .bool = stat.name_truncated });
        try obj.put(allocator, "calls", .{ .integer = @intCast(stat.calls) });
        try obj.put(allocator, "errors", .{ .integer = @intCast(stat.errors) });
        try obj.put(allocator, "error_rate_per_1000", .{ .integer = @intCast(ratePerThousand(stat.errors, stat.calls)) });
        try obj.put(allocator, "avg_latency_ms", .{ .integer = @intCast(if (stat.calls == 0) 0 else stat.total_latency_ms / stat.calls) });
        try obj.put(allocator, "max_latency_ms", .{ .integer = @intCast(stat.max_latency_ms) });
        try obj.put(allocator, "last_latency_ms", .{ .integer = @intCast(stat.last_latency_ms) });
        try obj.put(allocator, "last_error", .{ .bool = stat.last_error });
        try obj.put(allocator, "latency_samples_retained", .{ .integer = @intCast(stat.latency.retained()) });
        try obj.put(allocator, "latency_percentiles", try latencyPercentilesValue(allocator, stat.latency));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn latencyPercentilesValue(allocator: std.mem.Allocator, samples: LatencySamples) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const retained = samples.retained();
    try obj.put(allocator, "sample_capacity", .{ .integer = state_mod.max_latency_samples });
    try obj.put(allocator, "samples_seen", .{ .integer = @intCast(samples.sample_count) });
    try obj.put(allocator, "samples_retained", .{ .integer = @intCast(retained) });
    try obj.put(allocator, "minimum_samples", .{ .integer = state_mod.min_percentile_samples });
    if (retained < state_mod.min_percentile_samples) {
        try obj.put(allocator, "enough_samples", .{ .bool = false });
        try obj.put(allocator, "p50_ms", .null);
        try obj.put(allocator, "p95_ms", .null);
        try obj.put(allocator, "p99_ms", .null);
        try obj.put(allocator, "status", .{ .string = "insufficient_samples" });
        return .{ .object = obj };
    }

    var retained_samples: [state_mod.max_latency_samples]u64 = undefined;
    const first = firstSequence(samples.sample_count, state_mod.max_latency_samples);
    var sequence = first;
    var index: usize = 0;
    while (sequence <= samples.sample_count) : (sequence += 1) {
        retained_samples[index] = samples.samples[ringIndex(sequence, state_mod.max_latency_samples)];
        index += 1;
    }
    std.mem.sort(u64, retained_samples[0..retained], {}, std.sort.asc(u64));

    try obj.put(allocator, "enough_samples", .{ .bool = true });
    try obj.put(allocator, "p50_ms", .{ .integer = @intCast(percentile(retained_samples[0..retained], 50)) });
    try obj.put(allocator, "p95_ms", .{ .integer = @intCast(percentile(retained_samples[0..retained], 95)) });
    try obj.put(allocator, "p99_ms", .{ .integer = @intCast(percentile(retained_samples[0..retained], 99)) });
    try obj.put(allocator, "status", .{ .string = "ok" });
    return .{ .object = obj };
}

// Nearest-rank percentile on a pre-sorted slice.  The +99 makes the integer
// ceiling division produce a 1-based rank; we clamp to valid indices.
fn percentile(sorted: []const u64, p: u64) u64 {
    if (sorted.len == 0) return 0;
    const rank = (p * sorted.len + 99) / 100;
    const index = @min(sorted.len - 1, @max(@as(usize, 1), @as(usize, @intCast(rank))) - 1);
    return sorted[index];
}

fn toolCallCorrelationsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    const first = firstSequence(state.tool_call_correlation_count, state_mod.max_tool_call_correlations);
    var sequence = first;
    while (sequence <= state.tool_call_correlation_count) : (sequence += 1) {
        const event = &state.tool_call_correlations[ringIndex(sequence, state_mod.max_tool_call_correlations)];
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "sequence", .{ .integer = @intCast(event.sequence) });
        try obj.put(allocator, "tool_name", .{ .string = event.tool_name });
        try obj.put(allocator, "is_error", .{ .bool = event.is_error });
        try obj.put(allocator, "mcp_request_id", try observedRequestIdValue(allocator, event));
        try obj.put(allocator, "trace_id", .{ .string = event.traceId() });
        try obj.put(allocator, "span_id", .{ .string = event.spanId() });
        try obj.put(allocator, "parent_span_id", if (event.parentSpanId()) |span| .{ .string = span } else .null);
        try obj.put(allocator, "tool_call_id", .{ .string = event.toolCallId() });
        try obj.put(allocator, "tool_call_id_truncated", .{ .bool = event.tool_call_id_truncated });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn observedRequestIdValue(allocator: std.mem.Allocator, event: *const ToolCallCorrelation) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "type", .{ .string = event.mcp_request_id_type });
    try obj.put(allocator, "value", if (event.requestIdValue()) |value| .{ .string = value } else .null);
    try obj.put(allocator, "truncated", .{ .bool = event.mcp_request_id_truncated });
    return .{ .object = obj };
}

fn backendEventsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    const first = firstSequence(state.backend_event_count, state_mod.max_backend_events);
    var sequence = first;
    while (sequence <= state.backend_event_count) : (sequence += 1) {
        const event = state.backend_events[ringIndex(sequence, state_mod.max_backend_events)];
        var obj = std.json.ObjectMap.empty;
        errdefer obj.deinit(allocator);
        try obj.put(allocator, "sequence", .{ .integer = @intCast(event.sequence) });
        try obj.put(allocator, "backend", .{ .string = event.name });
        try obj.put(allocator, "ok", .{ .bool = event.ok });
        try obj.put(allocator, "status", .{ .string = event.status });
        try obj.put(allocator, "resolution", .{ .string = event.resolution });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn commandEventsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    const first = firstSequence(state.command_event_count, state_mod.max_command_events);
    var sequence = first;
    while (sequence <= state.command_event_count) : (sequence += 1) {
        const event = state.command_events[ringIndex(sequence, state_mod.max_command_events)];
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

fn startupPhasesValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    const first = firstSequence(state.startup_phase_count, state_mod.max_startup_phases);
    var sequence = first;
    while (sequence <= state.startup_phase_count) : (sequence += 1) {
        const phase = state.startup_phases[ringIndex(sequence, state_mod.max_startup_phases)];
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

fn cancellationEventsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    const first = firstSequence(state.cancellation_event_count, state_mod.max_cancellation_events);
    var sequence = first;
    while (sequence <= state.cancellation_event_count) : (sequence += 1) {
        const event = &state.cancellation_events[ringIndex(sequence, state_mod.max_cancellation_events)];
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

fn cancellationRequestIdValue(allocator: std.mem.Allocator, event: *const CancellationEvent) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "type", .{ .string = event.mcp_request_id_type });
    try obj.put(allocator, "value", if (event.requestIdValue()) |value| .{ .string = value } else .null);
    try obj.put(allocator, "truncated", .{ .bool = event.mcp_request_id_truncated });
    return .{ .object = obj };
}

fn zlsEventsValue(allocator: std.mem.Allocator, state: *const State, base: BaseMetrics) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    if (state.zls_event_count == 0) {
        // No transitions recorded yet (ZLS not enabled or never started).
        // Emit a synthetic sequence-0 event from the live snapshot so callers
        // always have at least one entry to display.
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

    const first = firstSequence(state.zls_event_count, state_mod.max_zls_events);
    var sequence = first;
    while (sequence <= state.zls_event_count) : (sequence += 1) {
        const event = state.zls_events[ringIndex(sequence, state_mod.max_zls_events)];
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

fn backendProbeCacheValue(allocator: std.mem.Allocator, cache: BackendProbeCacheSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "zig", try probeSnapshotValue(allocator, cache.zig));
    try obj.put(allocator, "zls", try probeSnapshotValue(allocator, cache.zls));
    try obj.put(allocator, "zwanzig", try probeSnapshotValue(allocator, cache.zwanzig));
    try obj.put(allocator, "zflame", try probeSnapshotValue(allocator, cache.zflame));
    try obj.put(allocator, "diff_folded", try probeSnapshotValue(allocator, cache.diff_folded));
    return .{ .object = obj };
}

fn probeSnapshotValue(allocator: std.mem.Allocator, probe: ?ProbeSnapshot) !std.json.Value {
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

fn optionalString(value: ?[]const u8) std.json.Value {
    return if (value) |text| .{ .string = text } else .null;
}

fn ratePerThousand(numerator: u64, denominator: u64) u64 {
    if (denominator == 0) return 0;
    return numerator * 1000 / denominator;
}

fn firstSequence(count: u64, capacity: u64) u64 {
    if (count <= capacity) return 1;
    return count - capacity + 1;
}

fn ringIndex(sequence: u64, comptime capacity: usize) usize {
    return @intCast((sequence - 1) % @as(u64, capacity));
}
