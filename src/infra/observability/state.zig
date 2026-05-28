const std = @import("std");

/// Fixed tool-stat capacity retained for process-local metrics.
pub const max_tool_stats = 64;
/// Fixed MCP method-stat capacity retained for process-local metrics.
pub const max_method_stats = 32;
/// Fixed latency sample ring capacity per observed key.
pub const max_latency_samples = 64;
/// Minimum retained samples before percentile fields are published.
pub const min_percentile_samples = 5;
/// Fixed recent tool-call correlation ring capacity.
pub const max_tool_call_correlations = 64;
/// Maximum retained request-id value bytes in observability state.
pub const max_request_id_value_len = 64;
/// Fixed command history ring capacity.
pub const max_command_events = 64;
/// Fixed backend probe history ring capacity.
pub const max_backend_events = 64;
/// Fixed ZLS status history ring capacity.
pub const max_zls_events = 64;
/// Fixed startup phase timing ring capacity.
pub const max_startup_phases = 24;
/// Fixed cancellation event ring capacity.
pub const max_cancellation_events = 32;

/// Bounded latency samples used for percentile computation.
pub const LatencySamples = struct {
    samples: [max_latency_samples]u64 = [_]u64{0} ** max_latency_samples,
    sample_count: u64 = 0,

    /// Appends a latency sample to the bounded ring.
    pub fn record(self: *LatencySamples, latency_ms: u64) void {
        const sequence = self.sample_count + 1;
        self.samples[ringIndex(sequence, max_latency_samples)] = latency_ms;
        self.sample_count = sequence;
    }

    /// Returns retained sample count.
    pub fn retained(self: LatencySamples) usize {
        return @intCast(@min(self.sample_count, max_latency_samples));
    }
};

/// Aggregated counters for one MCP tool name.
pub const ToolStats = struct {
    name: []const u8 = "",
    calls: u64 = 0,
    errors: u64 = 0,
    total_latency_ms: u64 = 0,
    max_latency_ms: u64 = 0,
    last_latency_ms: u64 = 0,
    last_error: bool = false,
    latency: LatencySamples = .{},
};

/// Aggregated counters for one MCP request method.
pub const MethodStats = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    name_truncated: bool = false,
    calls: u64 = 0,
    errors: u64 = 0,
    total_latency_ms: u64 = 0,
    max_latency_ms: u64 = 0,
    last_latency_ms: u64 = 0,
    last_error: bool = false,
    latency: LatencySamples = .{},

    /// Returns the retained method name.
    pub fn nameSlice(self: *const MethodStats) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// Borrowed correlation data supplied by the MCP adapter for one tool call.
pub const ToolCallCorrelationInput = struct {
    mcp_request_id_type: []const u8 = "null",
    mcp_request_id_value: ?[]const u8 = null,
    trace_id: []const u8 = "",
    span_id: []const u8 = "",
    parent_span_id: ?[]const u8 = null,
    tool_call_id: []const u8 = "",
};

/// Bounded process-local correlation event for one MCP tools/call response.
pub const ToolCallCorrelation = struct {
    sequence: u64 = 0,
    tool_name: []const u8 = "",
    is_error: bool = false,
    mcp_request_id_type: []const u8 = "null",
    mcp_request_id_value: [max_request_id_value_len]u8 = [_]u8{0} ** max_request_id_value_len,
    mcp_request_id_value_len: usize = 0,
    mcp_request_id_truncated: bool = false,
    trace_id: [32]u8 = [_]u8{'0'} ** 32,
    span_id: [16]u8 = [_]u8{'0'} ** 16,
    parent_span_id: ?[16]u8 = null,
    tool_call_id: [22]u8 = [_]u8{0} ** 22,
    tool_call_id_len: usize = 0,
    tool_call_id_truncated: bool = false,

    /// Returns the retained request-id value, or null when the request had no id.
    pub fn requestIdValue(self: *const ToolCallCorrelation) ?[]const u8 {
        if (std.mem.eql(u8, self.mcp_request_id_type, "null")) return null;
        return self.mcp_request_id_value[0..self.mcp_request_id_value_len];
    }

    /// Returns the retained trace id.
    pub fn traceId(self: *const ToolCallCorrelation) []const u8 {
        return self.trace_id[0..];
    }

    /// Returns the retained span id.
    pub fn spanId(self: *const ToolCallCorrelation) []const u8 {
        return self.span_id[0..];
    }

    /// Returns the retained parent span id, when present.
    pub fn parentSpanId(self: *const ToolCallCorrelation) ?[]const u8 {
        return if (self.parent_span_id) |span| span[0..] else null;
    }

    /// Returns the retained tool-call id.
    pub fn toolCallId(self: *const ToolCallCorrelation) []const u8 {
        return self.tool_call_id[0..self.tool_call_id_len];
    }
};

/// Bounded history event for one backend probe.
pub const BackendEvent = struct {
    sequence: u64 = 0,
    name: []const u8 = "",
    ok: bool = false,
    status: []const u8 = "",
    resolution: []const u8 = "",
};

/// Bounded history event for one ZLS status transition.
pub const ZlsEvent = struct {
    sequence: u64 = 0,
    status: []const u8 = "",
    failure: ?[]const u8 = null,
    restart_attempts: u64 = 0,
};

/// Bounded history event for one subprocess invocation.
pub const CommandEvent = struct {
    sequence: u64 = 0,
    title: []const u8 = "",
    argv0: []const u8 = "",
    duration_ms: i64 = 0,
    ok: bool = false,
    error_name: ?[]const u8 = null,
};

/// Startup phase timing captured with monotonic process-local offsets.
pub const StartupPhase = struct {
    sequence: u64 = 0,
    name: []const u8 = "",
    start_ms: u64 = 0,
    duration_ms: u64 = 0,
};

/// Bounded record of one cancellation notification outcome.
pub const CancellationEvent = struct {
    sequence: u64 = 0,
    status: []const u8 = "",
    mcp_request_id_type: []const u8 = "null",
    mcp_request_id_value: [max_request_id_value_len]u8 = [_]u8{0} ** max_request_id_value_len,
    mcp_request_id_value_len: usize = 0,
    mcp_request_id_truncated: bool = false,
    method: [64]u8 = [_]u8{0} ** 64,
    method_len: usize = 0,
    method_truncated: bool = false,

    /// Returns the retained request-id value, or null when none was present.
    pub fn requestIdValue(self: *const CancellationEvent) ?[]const u8 {
        if (std.mem.eql(u8, self.mcp_request_id_type, "null")) return null;
        return self.mcp_request_id_value[0..self.mcp_request_id_value_len];
    }

    /// Returns the retained method value.
    pub fn methodSlice(self: *const CancellationEvent) []const u8 {
        return self.method[0..self.method_len];
    }
};

/// Process-local observability state with bounded rings and saturating totals.
pub const State = struct {
    tool_stats: [max_tool_stats]ToolStats = [_]ToolStats{.{}} ** max_tool_stats,
    method_stats: [max_method_stats]MethodStats = [_]MethodStats{.{}} ** max_method_stats,
    tool_call_correlations: [max_tool_call_correlations]ToolCallCorrelation = [_]ToolCallCorrelation{.{}} ** max_tool_call_correlations,
    command_events: [max_command_events]CommandEvent = [_]CommandEvent{.{}} ** max_command_events,
    backend_events: [max_backend_events]BackendEvent = [_]BackendEvent{.{}} ** max_backend_events,
    zls_events: [max_zls_events]ZlsEvent = [_]ZlsEvent{.{}} ** max_zls_events,
    startup_phases: [max_startup_phases]StartupPhase = [_]StartupPhase{.{}} ** max_startup_phases,
    cancellation_events: [max_cancellation_events]CancellationEvent = [_]CancellationEvent{.{}} ** max_cancellation_events,
    tool_stat_count: usize = 0,
    method_stat_count: usize = 0,
    tool_call_correlation_count: u64 = 0,
    command_event_count: u64 = 0,
    backend_event_count: u64 = 0,
    zls_event_count: u64 = 0,
    startup_phase_count: u64 = 0,
    cancellation_event_count: u64 = 0,
    total_tool_calls: u64 = 0,
    total_tool_errors: u64 = 0,
    total_mcp_requests: u64 = 0,
    total_mcp_request_errors: u64 = 0,
    dropped_tool_stat_observations: u64 = 0,
    dropped_method_stat_observations: u64 = 0,
    truncated_method_names: u64 = 0,
    truncated_tool_call_request_ids: u64 = 0,
    truncated_tool_call_ids: u64 = 0,
    truncated_cancellation_request_ids: u64 = 0,
    truncated_cancellation_methods: u64 = 0,
    total_command_duration_ms: u64 = 0,
    command_latency: LatencySamples = .{},
    audit_enabled: bool = false,
    audit_mode: []const u8 = "disabled",
    audit_path: ?[]const u8 = null,
    audit_records_written: u64 = 0,
    audit_write_errors: u64 = 0,
    audit_last_error: ?[]const u8 = null,
    cancellation_requested: u64 = 0,
    cancellation_unknown: u64 = 0,
    cancellation_completed: u64 = 0,
    cancellation_uncancellable: u64 = 0,

    /// Records per-tool latency and error counters, dropping new names after capacity.
    pub fn recordToolCall(self: *State, name: []const u8, latency_ms: u64, is_error: bool) void {
        self.recordToolCallWithCorrelation(name, latency_ms, is_error, null);
    }

    /// Records per-tool counters plus optional bounded request correlation.
    pub fn recordToolCallWithCorrelation(self: *State, name: []const u8, latency_ms: u64, is_error: bool, correlation: ?ToolCallCorrelationInput) void {
        self.total_tool_calls += 1;
        if (is_error) self.total_tool_errors += 1;

        if (correlation) |fields| self.recordToolCallCorrelation(name, is_error, fields);

        const slot = self.toolSlot(name) orelse {
            self.dropped_tool_stat_observations +|= 1;
            return;
        };
        slot.calls += 1;
        if (is_error) slot.errors += 1;
        slot.total_latency_ms +|= latency_ms;
        slot.last_latency_ms = latency_ms;
        slot.last_error = is_error;
        slot.max_latency_ms = @max(slot.max_latency_ms, latency_ms);
        slot.latency.record(latency_ms);
    }

    /// Records per-MCP-method request latency and error counters.
    pub fn recordMcpRequest(self: *State, method: []const u8, latency_ms: u64, is_error: bool) void {
        self.total_mcp_requests += 1;
        if (is_error) self.total_mcp_request_errors += 1;

        const slot = self.methodSlot(method) orelse {
            self.dropped_method_stat_observations +|= 1;
            return;
        };
        slot.calls += 1;
        if (is_error) slot.errors += 1;
        slot.total_latency_ms +|= latency_ms;
        slot.last_latency_ms = latency_ms;
        slot.last_error = is_error;
        slot.max_latency_ms = @max(slot.max_latency_ms, latency_ms);
        slot.latency.record(latency_ms);
    }

    /// Appends request correlation to a bounded process-local ring.
    fn recordToolCallCorrelation(self: *State, name: []const u8, is_error: bool, fields: ToolCallCorrelationInput) void {
        const sequence = self.tool_call_correlation_count + 1;
        const index = ringIndex(sequence, max_tool_call_correlations);
        var event: ToolCallCorrelation = .{
            .sequence = sequence,
            .tool_name = name,
            .is_error = is_error,
            .mcp_request_id_type = fields.mcp_request_id_type,
        };
        if (fields.mcp_request_id_value) |value| {
            const copy_len = @min(value.len, event.mcp_request_id_value.len);
            @memcpy(event.mcp_request_id_value[0..copy_len], value[0..copy_len]);
            event.mcp_request_id_value_len = copy_len;
            event.mcp_request_id_truncated = value.len > copy_len;
            if (event.mcp_request_id_truncated) self.truncated_tool_call_request_ids +|= 1;
        }
        copyFixed(event.trace_id[0..], fields.trace_id, '0');
        copyFixed(event.span_id[0..], fields.span_id, '0');
        if (fields.parent_span_id) |parent| {
            var parent_copy: [16]u8 = [_]u8{'0'} ** 16;
            copyFixed(parent_copy[0..], parent, '0');
            event.parent_span_id = parent_copy;
        }
        const tool_call_copy_len = @min(fields.tool_call_id.len, event.tool_call_id.len);
        @memcpy(event.tool_call_id[0..tool_call_copy_len], fields.tool_call_id[0..tool_call_copy_len]);
        event.tool_call_id_len = tool_call_copy_len;
        if (fields.tool_call_id.len > tool_call_copy_len) {
            event.tool_call_id_truncated = true;
            self.truncated_tool_call_ids +|= 1;
        }

        self.tool_call_correlations[index] = event;
        self.tool_call_correlation_count = sequence;
    }

    /// Appends a backend probe result to the bounded ring.
    pub fn recordBackendProbe(self: *State, name: []const u8, ok: bool, status: []const u8, resolution: []const u8) void {
        const sequence = self.backend_event_count + 1;
        const index = ringIndex(sequence, max_backend_events);
        self.backend_events[index] = .{
            .sequence = sequence,
            .name = name,
            .ok = ok,
            .status = status,
            .resolution = resolution,
        };
        self.backend_event_count = sequence;
    }

    /// Appends a command event and accumulates non-negative duration.
    pub fn recordCommand(self: *State, title: []const u8, argv: []const []const u8, duration_ms: i64, ok: bool, error_name: ?[]const u8) void {
        const sequence = self.command_event_count + 1;
        const index = ringIndex(sequence, max_command_events);
        const safe_duration: u64 = if (duration_ms <= 0) 0 else @intCast(duration_ms);
        self.command_events[index] = .{
            .sequence = sequence,
            .title = title,
            .argv0 = if (argv.len > 0) argv[0] else "",
            .duration_ms = @intCast(safe_duration),
            .ok = ok,
            .error_name = error_name,
        };
        self.total_command_duration_ms +|= safe_duration;
        self.command_latency.record(safe_duration);
        self.command_event_count = sequence;
    }

    /// Records one monotonic startup phase timing.
    pub fn recordStartupPhase(self: *State, name: []const u8, start_ms: u64, duration_ms: u64) void {
        const sequence = self.startup_phase_count + 1;
        const index = ringIndex(sequence, max_startup_phases);
        self.startup_phases[index] = .{
            .sequence = sequence,
            .name = name,
            .start_ms = start_ms,
            .duration_ms = duration_ms,
        };
        self.startup_phase_count = sequence;
    }

    /// Records audit mode once bootstrap successfully enables the writer.
    pub fn recordAuditEnabled(self: *State, mode: []const u8, path: []const u8) void {
        self.audit_enabled = true;
        self.audit_mode = mode;
        self.audit_path = path;
    }

    /// Records one successful audit append.
    pub fn recordAuditWriteOk(self: *State) void {
        self.audit_records_written +|= 1;
    }

    /// Records one failed audit append without affecting JSON-RPC stdout.
    pub fn recordAuditWriteError(self: *State, err_name: []const u8) void {
        self.audit_write_errors +|= 1;
        self.audit_last_error = err_name;
    }

    /// Records an inbound cancellation notification outcome.
    pub fn recordCancellation(self: *State, status: []const u8, request_id_type: []const u8, request_id_value: ?[]const u8, method: ?[]const u8) void {
        self.cancellation_requested +|= 1;
        if (std.mem.eql(u8, status, "unknown")) self.cancellation_unknown +|= 1;
        if (std.mem.eql(u8, status, "completed") or std.mem.eql(u8, status, "completed_late")) self.cancellation_completed +|= 1;
        if (std.mem.eql(u8, status, "uncancellable") or std.mem.eql(u8, status, "not_cancellable")) self.cancellation_uncancellable +|= 1;

        const sequence = self.cancellation_event_count + 1;
        const index = ringIndex(sequence, max_cancellation_events);
        var event: CancellationEvent = .{
            .sequence = sequence,
            .status = status,
            .mcp_request_id_type = request_id_type,
        };
        if (request_id_value) |value| {
            const copy_len = @min(value.len, event.mcp_request_id_value.len);
            @memcpy(event.mcp_request_id_value[0..copy_len], value[0..copy_len]);
            event.mcp_request_id_value_len = copy_len;
            event.mcp_request_id_truncated = value.len > copy_len;
            if (event.mcp_request_id_truncated) self.truncated_cancellation_request_ids +|= 1;
        }
        if (method) |value| {
            const copy_len = @min(value.len, event.method.len);
            @memcpy(event.method[0..copy_len], value[0..copy_len]);
            event.method_len = copy_len;
            event.method_truncated = value.len > copy_len;
            if (event.method_truncated) self.truncated_cancellation_methods +|= 1;
        }
        self.cancellation_events[index] = event;
        self.cancellation_event_count = sequence;
    }

    /// Records ZLS status transitions, suppressing consecutive duplicates.
    pub fn recordZlsStatus(self: *State, status: []const u8, failure: ?[]const u8, restart_attempts: u64) void {
        if (self.zls_event_count > 0) {
            const previous = self.zls_events[ringIndex(self.zls_event_count, max_zls_events)];
            if (std.mem.eql(u8, previous.status, status) and optionalStringEqual(previous.failure, failure) and previous.restart_attempts == restart_attempts) return;
        }

        const sequence = self.zls_event_count + 1;
        const index = ringIndex(sequence, max_zls_events);
        self.zls_events[index] = .{
            .sequence = sequence,
            .status = status,
            .failure = failure,
            .restart_attempts = restart_attempts,
        };
        self.zls_event_count = sequence;
    }

    /// Returns the mutable metrics slot for a tool name.
    fn toolSlot(self: *State, name: []const u8) ?*ToolStats {
        for (self.tool_stats[0..self.tool_stat_count]) |*stat| {
            if (std.mem.eql(u8, stat.name, name)) return stat;
        }
        if (self.tool_stat_count < self.tool_stats.len) {
            const index = self.tool_stat_count;
            self.tool_stat_count += 1;
            self.tool_stats[index] = .{ .name = name };
            return &self.tool_stats[index];
        }
        return null;
    }

    /// Returns the mutable metrics slot for an MCP method name.
    fn methodSlot(self: *State, name: []const u8) ?*MethodStats {
        for (self.method_stats[0..self.method_stat_count]) |*stat| {
            if (methodNameMatches(stat, name)) return stat;
        }
        if (self.method_stat_count < self.method_stats.len) {
            const index = self.method_stat_count;
            self.method_stat_count += 1;
            self.method_stats[index] = .{};
            const copy_len = @min(name.len, self.method_stats[index].name.len);
            @memcpy(self.method_stats[index].name[0..copy_len], name[0..copy_len]);
            self.method_stats[index].name_len = copy_len;
            self.method_stats[index].name_truncated = name.len > copy_len;
            if (self.method_stats[index].name_truncated) self.truncated_method_names +|= 1;
            return &self.method_stats[index];
        }
        return null;
    }
};

/// Renders all current observability state as the metrics v2 JSON object.
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

/// Snapshot of non-observability counters supplied by runtime composition.
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

/// Snapshot of static-analysis cache state.
pub const AnalysisCacheSnapshot = struct {
    present: bool = false,
    hits: usize = 0,
    refreshes: usize = 0,
    bytes: usize = 0,
};

/// Snapshot of artifact registry scan state.
pub const ArtifactMetrics = struct {
    registry_available: bool = false,
    registry_entries: usize = 0,
    scanned_artifacts: usize = 0,
    scan_limit: usize = 0,
    status: []const u8 = "not_scanned",
};

/// Current backend probe cache keyed by supported backend name.
pub const BackendProbeCacheSnapshot = struct {
    zig: ?ProbeSnapshot = null,
    zls: ?ProbeSnapshot = null,
    zwanzig: ?ProbeSnapshot = null,
    zflame: ?ProbeSnapshot = null,
    diff_folded: ?ProbeSnapshot = null,
};

/// Latest known state for one backend probe.
pub const ProbeSnapshot = struct {
    ok: bool,
    status: []const u8,
    resolution: []const u8,
};

/// Renders bounded backend probe history plus current probe cache.
pub fn backendHistoryValue(allocator: std.mem.Allocator, state: *const State, base: BaseMetrics) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_backend_health_history" });
    try obj.put(allocator, "history_capacity", .{ .integer = max_backend_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(state.backend_event_count) });
    try obj.put(allocator, "events", try backendEventsValue(allocator, state));
    try obj.put(allocator, "current_probe_cache", try backendProbeCacheValue(allocator, base.backend_probe_cache));
    try obj.put(allocator, "resolution", .{ .string = "Call zigars_doctor with probe_backends=true to refresh optional backend health; this history records probes observed in the current server process." });
    return .{ .object = obj };
}

/// Renders bounded ZLS status transitions, or the current snapshot when empty.
pub fn zlsTimelineValue(allocator: std.mem.Allocator, state: *const State, base: BaseMetrics) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_zls_timeline" });
    try obj.put(allocator, "history_capacity", .{ .integer = max_zls_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(state.zls_event_count) });
    try obj.put(allocator, "current_status", .{ .string = base.zls_status });
    try obj.put(allocator, "current_failure", optionalString(base.zls_last_failure));
    try obj.put(allocator, "restart_attempts", .{ .integer = @intCast(base.zls_restart_attempts) });
    try obj.put(allocator, "events", try zlsEventsValue(allocator, state, base));
    try obj.put(allocator, "timeline_clock", .{ .string = "monotonic_sequence" });
    return .{ .object = obj };
}

/// Renders per-tool latency/error counters.
pub fn toolLatencyValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_tool_latency" });
    try obj.put(allocator, "observed_tool_calls", .{ .integer = @intCast(state.total_tool_calls) });
    try obj.put(allocator, "observed_tool_errors", .{ .integer = @intCast(state.total_tool_errors) });
    try obj.put(allocator, "tool_stat_capacity", .{ .integer = max_tool_stats });
    try obj.put(allocator, "tool_count", .{ .integer = @intCast(state.tool_stat_count) });
    try obj.put(allocator, "dropped_tool_stat_observations", .{ .integer = @intCast(state.dropped_tool_stat_observations) });
    try obj.put(allocator, "tools", try toolStatsValue(allocator, state));
    try obj.put(allocator, "correlation_history_capacity", .{ .integer = max_tool_call_correlations });
    try obj.put(allocator, "recorded_correlations", .{ .integer = @intCast(state.tool_call_correlation_count) });
    try obj.put(allocator, "truncated_request_id_values", .{ .integer = @intCast(state.truncated_tool_call_request_ids) });
    try obj.put(allocator, "truncated_tool_call_ids", .{ .integer = @intCast(state.truncated_tool_call_ids) });
    try obj.put(allocator, "recent_tool_call_correlations", try toolCallCorrelationsValue(allocator, state));
    try obj.put(allocator, "units", .{ .string = "milliseconds" });
    try obj.put(allocator, "resolution", .{ .string = "Latency is measured around MCP schema validation and handler dispatch inside the current zigars process." });
    return .{ .object = obj };
}

/// Renders MCP request method latency counters.
pub fn methodLatencyValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_mcp_method_latency" });
    try obj.put(allocator, "observed_mcp_requests", .{ .integer = @intCast(state.total_mcp_requests) });
    try obj.put(allocator, "observed_mcp_request_errors", .{ .integer = @intCast(state.total_mcp_request_errors) });
    try obj.put(allocator, "method_stat_capacity", .{ .integer = max_method_stats });
    try obj.put(allocator, "method_count", .{ .integer = @intCast(state.method_stat_count) });
    try obj.put(allocator, "dropped_method_stat_observations", .{ .integer = @intCast(state.dropped_method_stat_observations) });
    try obj.put(allocator, "truncated_method_names", .{ .integer = @intCast(state.truncated_method_names) });
    try obj.put(allocator, "methods", try methodStatsValue(allocator, state));
    try obj.put(allocator, "units", .{ .string = "milliseconds" });
    try obj.put(allocator, "resolution", .{ .string = "Request method latency is measured inside the current zigars process and resets on restart." });
    return .{ .object = obj };
}

/// Renders bounded subprocess duration history.
pub fn commandDurationsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_command_durations" });
    try obj.put(allocator, "history_capacity", .{ .integer = max_command_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(state.command_event_count) });
    try obj.put(allocator, "avg_duration_ms", .{ .integer = @intCast(if (state.command_event_count == 0) 0 else state.total_command_duration_ms / state.command_event_count) });
    try obj.put(allocator, "latency_percentiles", try latencyPercentilesValue(allocator, state.command_latency));
    try obj.put(allocator, "events", try commandEventsValue(allocator, state));
    try obj.put(allocator, "resolution", .{ .string = "Command durations are observed for commands routed through shared zigars command helpers in the current server process." });
    return .{ .object = obj };
}

/// Renders process-local startup phase timings.
pub fn startupTimingsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_startup_timings" });
    try obj.put(allocator, "clock", .{ .string = "monotonic_awake" });
    try obj.put(allocator, "history_capacity", .{ .integer = max_startup_phases });
    try obj.put(allocator, "recorded_phases", .{ .integer = @intCast(state.startup_phase_count) });
    try obj.put(allocator, "phases", try startupPhasesValue(allocator, state));
    try obj.put(allocator, "resolution", .{ .string = "Startup timings are process-local, runtime-specific, and reset when zigars restarts." });
    return .{ .object = obj };
}

/// Renders audit logging runtime state.
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

/// Renders cancellation notification outcomes.
pub fn cancellationValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_request_cancellation" });
    try obj.put(allocator, "requested", .{ .integer = @intCast(state.cancellation_requested) });
    try obj.put(allocator, "unknown", .{ .integer = @intCast(state.cancellation_unknown) });
    try obj.put(allocator, "completed", .{ .integer = @intCast(state.cancellation_completed) });
    try obj.put(allocator, "uncancellable", .{ .integer = @intCast(state.cancellation_uncancellable) });
    try obj.put(allocator, "history_capacity", .{ .integer = max_cancellation_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(state.cancellation_event_count) });
    try obj.put(allocator, "truncated_request_id_values", .{ .integer = @intCast(state.truncated_cancellation_request_ids) });
    try obj.put(allocator, "truncated_methods", .{ .integer = @intCast(state.truncated_cancellation_methods) });
    try obj.put(allocator, "events", try cancellationEventsValue(allocator, state));
    try obj.put(allocator, "resolution", .{ .string = "Cancellation is cooperative and process-local; sequential dispatch can observe notifications while the server is reading MCP messages or waiting on helper protocol responses." });
    return .{ .object = obj };
}

/// Renders capacity, overflow, and truncation counters for bounded observability state.
fn retentionValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigars_observability_retention" });
    try obj.put(allocator, "tool_stat_capacity", .{ .integer = max_tool_stats });
    try obj.put(allocator, "tool_stat_count", .{ .integer = @intCast(state.tool_stat_count) });
    try obj.put(allocator, "dropped_tool_stat_observations", .{ .integer = @intCast(state.dropped_tool_stat_observations) });
    try obj.put(allocator, "method_stat_capacity", .{ .integer = max_method_stats });
    try obj.put(allocator, "method_stat_count", .{ .integer = @intCast(state.method_stat_count) });
    try obj.put(allocator, "dropped_method_stat_observations", .{ .integer = @intCast(state.dropped_method_stat_observations) });
    try obj.put(allocator, "truncated_method_names", .{ .integer = @intCast(state.truncated_method_names) });
    try obj.put(allocator, "request_id_value_capacity", .{ .integer = max_request_id_value_len });
    try obj.put(allocator, "truncated_tool_call_request_ids", .{ .integer = @intCast(state.truncated_tool_call_request_ids) });
    try obj.put(allocator, "truncated_tool_call_ids", .{ .integer = @intCast(state.truncated_tool_call_ids) });
    try obj.put(allocator, "truncated_cancellation_request_ids", .{ .integer = @intCast(state.truncated_cancellation_request_ids) });
    try obj.put(allocator, "truncated_cancellation_methods", .{ .integer = @intCast(state.truncated_cancellation_methods) });
    return .{ .object = obj };
}

/// Builds a snapshot of analysis-cache metrics.
fn analysisCacheValue(allocator: std.mem.Allocator, cache: AnalysisCacheSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "present", .{ .bool = cache.present });
    try obj.put(allocator, "hits", .{ .integer = @intCast(cache.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(cache.refreshes) });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(cache.bytes) });
    return .{ .object = obj };
}

/// Builds a snapshot of artifact-store metrics.
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

/// Builds a snapshot of tool invocation metrics.
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

/// Builds a snapshot of MCP method invocation metrics.
fn methodStatsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (state.method_stats[0..state.method_stat_count]) |stat| {
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

/// Builds percentile fields from a bounded latency sample ring.
fn latencyPercentilesValue(allocator: std.mem.Allocator, samples: LatencySamples) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const retained = samples.retained();
    try obj.put(allocator, "sample_capacity", .{ .integer = max_latency_samples });
    try obj.put(allocator, "samples_seen", .{ .integer = @intCast(samples.sample_count) });
    try obj.put(allocator, "samples_retained", .{ .integer = @intCast(retained) });
    try obj.put(allocator, "minimum_samples", .{ .integer = min_percentile_samples });
    if (retained < min_percentile_samples) {
        try obj.put(allocator, "enough_samples", .{ .bool = false });
        try obj.put(allocator, "p50_ms", .null);
        try obj.put(allocator, "p95_ms", .null);
        try obj.put(allocator, "p99_ms", .null);
        try obj.put(allocator, "status", .{ .string = "insufficient_samples" });
        return .{ .object = obj };
    }

    var retained_samples: [max_latency_samples]u64 = undefined;
    const first = firstSequence(samples.sample_count, max_latency_samples);
    var sequence = first;
    var index: usize = 0;
    while (sequence <= samples.sample_count) : (sequence += 1) {
        retained_samples[index] = samples.samples[ringIndex(sequence, max_latency_samples)];
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

/// Nearest-rank percentile over a sorted non-empty sample slice.
fn percentile(sorted: []const u64, p: u64) u64 {
    if (sorted.len == 0) return 0;
    const rank = (p * sorted.len + 99) / 100;
    const index = @min(sorted.len - 1, @max(@as(usize, 1), @as(usize, @intCast(rank))) - 1);
    return sorted[index];
}

/// Builds bounded request correlation events for recent tool calls.
fn toolCallCorrelationsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    const first = firstSequence(state.tool_call_correlation_count, max_tool_call_correlations);
    var sequence = first;
    while (sequence <= state.tool_call_correlation_count) : (sequence += 1) {
        const event = &state.tool_call_correlations[ringIndex(sequence, max_tool_call_correlations)];
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

/// Builds the normalized request id object for an observed tool call.
fn observedRequestIdValue(allocator: std.mem.Allocator, event: *const ToolCallCorrelation) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "type", .{ .string = event.mcp_request_id_type });
    try obj.put(allocator, "value", if (event.requestIdValue()) |value| .{ .string = value } else .null);
    try obj.put(allocator, "truncated", .{ .bool = event.mcp_request_id_truncated });
    return .{ .object = obj };
}

/// Builds a snapshot of backend event counters.
fn backendEventsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    const first = firstSequence(state.backend_event_count, max_backend_events);
    var sequence = first;
    while (sequence <= state.backend_event_count) : (sequence += 1) {
        const event = state.backend_events[ringIndex(sequence, max_backend_events)];
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

/// Builds a snapshot of command execution counters.
fn commandEventsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    const first = firstSequence(state.command_event_count, max_command_events);
    var sequence = first;
    while (sequence <= state.command_event_count) : (sequence += 1) {
        const event = state.command_events[ringIndex(sequence, max_command_events)];
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

/// Builds a snapshot of startup phase timings.
fn startupPhasesValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    const first = firstSequence(state.startup_phase_count, max_startup_phases);
    var sequence = first;
    while (sequence <= state.startup_phase_count) : (sequence += 1) {
        const phase = state.startup_phases[ringIndex(sequence, max_startup_phases)];
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

/// Builds a snapshot of cancellation notification outcomes.
fn cancellationEventsValue(allocator: std.mem.Allocator, state: *const State) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    const first = firstSequence(state.cancellation_event_count, max_cancellation_events);
    var sequence = first;
    while (sequence <= state.cancellation_event_count) : (sequence += 1) {
        const event = &state.cancellation_events[ringIndex(sequence, max_cancellation_events)];
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

/// Builds normalized request-id JSON for a cancellation event.
fn cancellationRequestIdValue(allocator: std.mem.Allocator, event: *const CancellationEvent) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "type", .{ .string = event.mcp_request_id_type });
    try obj.put(allocator, "value", if (event.requestIdValue()) |value| .{ .string = value } else .null);
    try obj.put(allocator, "truncated", .{ .bool = event.mcp_request_id_truncated });
    return .{ .object = obj };
}

/// Builds a snapshot of ZLS event counters.
fn zlsEventsValue(allocator: std.mem.Allocator, state: *const State, base: BaseMetrics) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    if (state.zls_event_count == 0) {
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

    const first = firstSequence(state.zls_event_count, max_zls_events);
    var sequence = first;
    while (sequence <= state.zls_event_count) : (sequence += 1) {
        const event = state.zls_events[ringIndex(sequence, max_zls_events)];
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

/// Builds a snapshot of backend probe cache metrics.
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

/// Builds a snapshot of one backend probe result.
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

/// Builds a snapshot of recorded runtime limitations.
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

/// Converts an optional string into a JSON value.
fn optionalString(value: ?[]const u8) std.json.Value {
    return if (value) |text| .{ .string = text } else .null;
}

/// Compares optional string by the fields that affect behavior.
fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Matches method stats by full name, or by retained prefix when the name was truncated.
fn methodNameMatches(stat: *const MethodStats, name: []const u8) bool {
    const retained = stat.nameSlice();
    if (!stat.name_truncated) return std.mem.eql(u8, retained, name);
    return name.len >= retained.len and std.mem.eql(u8, retained, name[0..retained.len]);
}

/// Calculates a per-thousand rate with zero-denominator protection.
fn ratePerThousand(numerator: u64, denominator: u64) u64 {
    if (denominator == 0) return 0;
    return numerator * 1000 / denominator;
}

/// Finds the first sequence number retained in a ring buffer.
fn firstSequence(count: u64, capacity: u64) u64 {
    if (count <= capacity) return 1;
    return count - capacity + 1;
}

/// Maps a sequence number to its ring-buffer index.
fn ringIndex(sequence: u64, comptime capacity: usize) usize {
    return @intCast((sequence - 1) % @as(u64, capacity));
}

/// Copies a bounded source into a fixed destination and pads the remainder.
fn copyFixed(dest: []u8, source: []const u8, pad: u8) void {
    const copy_len = @min(dest.len, source.len);
    @memcpy(dest[0..copy_len], source[0..copy_len]);
    if (copy_len < dest.len) @memset(dest[copy_len..], pad);
}

test "observability state records rings and renders populated metrics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = State{};
    state.recordToolCall("zig_version", 10, false);
    state.recordToolCall("zig_version", 20, true);
    state.recordToolCall("zig_build", 5, false);
    state.recordBackendProbe("zig", true, "ok", "backend command completed");
    state.recordBackendProbe("zls", false, "missing", "install zls");
    state.recordCommand("zig build", &.{ "zig", "build" }, 15, true, null);
    state.recordCommand("empty argv", &.{}, -1, false, "Timeout");
    state.recordZlsStatus("connected", null, 0);
    state.recordZlsStatus("connected", null, 0);
    state.recordZlsStatus("failed", "FileNotFound", 1);
    state.recordZlsStatus("failed", "FileNotFound", 1);
    state.recordZlsStatus("failed", null, 1);

    const base = BaseMetrics{
        .workspace = "/workspace",
        .command_calls = 4,
        .zls_requests = 5,
        .tool_errors = 1,
        .zls_status = "failed",
        .zls_last_failure = "FileNotFound",
        .zls_restart_attempts = 2,
        .backend_probe_cache = .{
            .zig = .{ .ok = true, .status = "ok", .resolution = "backend command completed" },
            .zls = .{ .ok = false, .status = "missing", .resolution = "install zls" },
        },
        .analysis_cache = .{ .present = true, .hits = 1, .refreshes = 2, .bytes = 3 },
        .artifacts = .{ .registry_available = true, .registry_entries = 1, .scanned_artifacts = 2, .scan_limit = 3, .status = "ok" },
    };

    const metrics = try metricsV2Value(allocator, &state, base);
    try std.testing.expectEqualStrings("zigars_metrics_v2", metrics.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 3), metrics.object.get("observed_tool_calls").?.integer);

    const backend_history = try backendHistoryValue(allocator, &state, base);
    try std.testing.expectEqual(@as(usize, 2), backend_history.object.get("events").?.array.items.len);

    const timeline = try zlsTimelineValue(allocator, &state, base);
    try std.testing.expectEqualStrings("runtime_transition", timeline.object.get("events").?.array.items[0].object.get("source").?.string);

    const latency = try toolLatencyValue(allocator, &state);
    const first_tool = latency.object.get("tools").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 500), first_tool.get("error_rate_per_1000").?.integer);

    const durations = try commandDurationsValue(allocator, &state);
    const second_command = durations.object.get("events").?.array.items[1].object;
    try std.testing.expectEqualStrings("", second_command.get("argv0").?.string);
    try std.testing.expectEqualStrings("Timeout", second_command.get("error").?.string);
}

test "zls timeline falls back to current snapshot when no transitions were observed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const base = BaseMetrics{
        .workspace = "/workspace",
        .command_calls = 0,
        .zls_requests = 0,
        .tool_errors = 0,
        .zls_status = "not_started",
        .zls_last_failure = null,
        .zls_restart_attempts = 0,
        .backend_probe_cache = .{},
        .analysis_cache = .{},
        .artifacts = .{},
    };

    const empty_state = State{};
    const timeline = try zlsTimelineValue(allocator, &empty_state, base);
    const event = timeline.object.get("events").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 0), event.get("sequence").?.integer);
    try std.testing.expectEqualStrings("current_snapshot", event.get("source").?.string);
    try std.testing.expect(event.get("failure").? == .null);
}

test "observability metric builders clean up partially allocated JSON" {
    // Fixture values shared by this test module.
    const Fixture = struct {
        fn state() State {
            var s = State{};
            s.recordToolCall("zig_version", 10, false);
            s.recordToolCall("zig_version", 20, true);
            s.recordBackendProbe("zig", true, "ok", "backend command completed");
            s.recordCommand("zig build", &.{ "zig", "build" }, 15, true, null);
            s.recordZlsStatus("failed", "FileNotFound", 1);
            return s;
        }

        fn base() BaseMetrics {
            return .{
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
            };
        }
    };

    var fail_index: usize = 0;
    while (fail_index < 256) : (fail_index += 1) {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        const state = Fixture.state();
        const base = Fixture.base();

        if (metricsV2Value(allocator, &state, base)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (backendHistoryValue(allocator, &state, base)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (zlsTimelineValue(allocator, &state, base)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (toolLatencyValue(allocator, &state)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (toolCallCorrelationsValue(allocator, &state)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (commandDurationsValue(allocator, &state)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        const empty_state = State{};
        if (zlsTimelineValue(allocator, &empty_state, base)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (backendProbeCacheValue(allocator, base.backend_probe_cache)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (probeSnapshotValue(allocator, base.backend_probe_cache.zig)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (probeSnapshotValue(allocator, null)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (limitationsValue(allocator)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}

test "observability state retains bounded tool-call correlation and resets with new state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = State{};
    var sequence: u64 = 1;
    while (sequence <= max_tool_call_correlations + 2) : (sequence += 1) {
        var trace: [32]u8 = [_]u8{'0'} ** 32;
        var span: [16]u8 = [_]u8{'0'} ** 16;
        const trace_text = std.fmt.bufPrint(&trace, "0000000000000000000000000000{x:0>4}", .{sequence}) catch unreachable;
        const span_text = std.fmt.bufPrint(&span, "000000000000{x:0>4}", .{sequence}) catch unreachable;
        state.recordToolCallWithCorrelation("zig_check", sequence, sequence % 2 == 0, .{
            .mcp_request_id_type = "integer",
            .mcp_request_id_value = "42",
            .trace_id = trace_text,
            .span_id = span_text,
            .tool_call_id = "zigars-tc-000000000001",
        });
    }

    try std.testing.expectEqual(@as(u64, max_tool_call_correlations + 2), state.tool_call_correlation_count);
    const value = try toolLatencyValue(allocator, &state);
    const recent = value.object.get("recent_tool_call_correlations").?.array;
    try std.testing.expectEqual(@as(usize, max_tool_call_correlations), recent.items.len);
    try std.testing.expectEqual(@as(i64, 3), recent.items[0].object.get("sequence").?.integer);
    try std.testing.expectEqualStrings("integer", recent.items[0].object.get("mcp_request_id").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("42", recent.items[0].object.get("mcp_request_id").?.object.get("value").?.string);

    const restarted = State{};
    try std.testing.expectEqual(@as(u64, 0), restarted.tool_call_correlation_count);
    try std.testing.expectEqual(@as(u64, 0), restarted.total_tool_calls);
}

test "observability state reports capacity drops and truncated identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = State{};
    var tool_names: [max_tool_stats + 1][16]u8 = undefined;
    for (tool_names[0..], 0..) |*buffer, index| {
        const name = try std.fmt.bufPrint(buffer, "tool_{d}", .{index});
        state.recordToolCall(name, 1, false);
    }
    try std.testing.expectEqual(@as(usize, max_tool_stats), state.tool_stat_count);
    try std.testing.expectEqual(@as(u64, 1), state.dropped_tool_stat_observations);

    const long_request_id: [max_request_id_value_len + 8]u8 = [_]u8{'r'} ** (max_request_id_value_len + 8);
    state.recordToolCallWithCorrelation("tool_0", 2, false, .{
        .mcp_request_id_type = "string",
        .mcp_request_id_value = long_request_id[0..],
        .trace_id = "0123456789abcdef0123456789abcdef",
        .span_id = "0123456789abcdef",
        .tool_call_id = "tool-call-id-longer-than-twenty-two",
    });
    try std.testing.expectEqual(@as(u64, 1), state.truncated_tool_call_request_ids);
    try std.testing.expectEqual(@as(u64, 1), state.truncated_tool_call_ids);

    const long_method: [80]u8 = [_]u8{'m'} ** 80;
    state.recordMcpRequest(long_method[0..], 1, false);
    state.recordMcpRequest(long_method[0..], 2, true);
    try std.testing.expectEqual(@as(usize, 1), state.method_stat_count);
    try std.testing.expectEqual(@as(u64, 1), state.truncated_method_names);
    try std.testing.expectEqual(@as(u64, 2), state.method_stats[0].calls);
    try std.testing.expectEqual(@as(u64, 1), state.method_stats[0].errors);

    var method_names: [max_method_stats][20]u8 = undefined;
    for (method_names[0..], 0..) |*buffer, index| {
        const name = try std.fmt.bufPrint(buffer, "method/{d}", .{index});
        state.recordMcpRequest(name, 1, false);
    }
    try std.testing.expectEqual(@as(usize, max_method_stats), state.method_stat_count);
    try std.testing.expectEqual(@as(u64, 1), state.dropped_method_stat_observations);

    const cancellation_method: [80]u8 = [_]u8{'c'} ** 80;
    state.recordCancellation("unknown", "string", long_request_id[0..], cancellation_method[0..]);
    try std.testing.expectEqual(@as(u64, 1), state.truncated_cancellation_request_ids);
    try std.testing.expectEqual(@as(u64, 1), state.truncated_cancellation_methods);

    const tool_latency = try toolLatencyValue(allocator, &state);
    try std.testing.expectEqual(@as(i64, 1), tool_latency.object.get("dropped_tool_stat_observations").?.integer);
    try std.testing.expectEqual(@as(i64, 1), tool_latency.object.get("truncated_request_id_values").?.integer);
    try std.testing.expectEqual(@as(i64, 1), tool_latency.object.get("truncated_tool_call_ids").?.integer);
    const correlation = tool_latency.object.get("recent_tool_call_correlations").?.array.items[0].object;
    try std.testing.expect(correlation.get("mcp_request_id").?.object.get("truncated").?.bool);
    try std.testing.expect(correlation.get("tool_call_id_truncated").?.bool);

    const method_latency = try methodLatencyValue(allocator, &state);
    try std.testing.expectEqual(@as(i64, 1), method_latency.object.get("dropped_method_stat_observations").?.integer);
    try std.testing.expectEqual(@as(i64, 1), method_latency.object.get("truncated_method_names").?.integer);

    const cancellation = try cancellationValue(allocator, &state);
    try std.testing.expectEqual(@as(i64, 1), cancellation.object.get("truncated_request_id_values").?.integer);
    try std.testing.expectEqual(@as(i64, 1), cancellation.object.get("truncated_methods").?.integer);

    const retention = try retentionValue(allocator, &state);
    try std.testing.expectEqual(@as(i64, 1), retention.object.get("dropped_tool_stat_observations").?.integer);
    try std.testing.expectEqual(@as(i64, 1), retention.object.get("dropped_method_stat_observations").?.integer);
    try std.testing.expectEqual(@as(i64, 1), retention.object.get("truncated_tool_call_request_ids").?.integer);
    try std.testing.expectEqual(@as(i64, 1), retention.object.get("truncated_cancellation_methods").?.integer);
}
