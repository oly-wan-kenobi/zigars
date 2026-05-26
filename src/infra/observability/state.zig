const std = @import("std");

/// Fixed tool-stat capacity retained for process-local metrics.
pub const max_tool_stats = 64;
/// Fixed command history ring capacity.
pub const max_command_events = 64;
/// Fixed backend probe history ring capacity.
pub const max_backend_events = 64;
/// Fixed ZLS status history ring capacity.
pub const max_zls_events = 64;

/// Aggregated counters for one MCP tool name.
pub const ToolStats = struct {
    name: []const u8 = "",
    calls: u64 = 0,
    errors: u64 = 0,
    total_latency_ms: u64 = 0,
    max_latency_ms: u64 = 0,
    last_latency_ms: u64 = 0,
    last_error: bool = false,
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

/// Process-local observability state with bounded rings and saturating totals.
pub const State = struct {
    tool_stats: [max_tool_stats]ToolStats = [_]ToolStats{.{}} ** max_tool_stats,
    command_events: [max_command_events]CommandEvent = [_]CommandEvent{.{}} ** max_command_events,
    backend_events: [max_backend_events]BackendEvent = [_]BackendEvent{.{}} ** max_backend_events,
    zls_events: [max_zls_events]ZlsEvent = [_]ZlsEvent{.{}} ** max_zls_events,
    tool_stat_count: usize = 0,
    command_event_count: u64 = 0,
    backend_event_count: u64 = 0,
    zls_event_count: u64 = 0,
    total_tool_calls: u64 = 0,
    total_tool_errors: u64 = 0,
    total_command_duration_ms: u64 = 0,

    /// Records per-tool latency and error counters, dropping new names after capacity.
    pub fn recordToolCall(self: *State, name: []const u8, latency_ms: u64, is_error: bool) void {
        self.total_tool_calls += 1;
        if (is_error) self.total_tool_errors += 1;

        const slot = self.toolSlot(name) orelse return;
        slot.calls += 1;
        if (is_error) slot.errors += 1;
        slot.total_latency_ms +|= latency_ms;
        slot.last_latency_ms = latency_ms;
        slot.last_error = is_error;
        slot.max_latency_ms = @max(slot.max_latency_ms, latency_ms);
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
        self.command_event_count = sequence;
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
};

/// Renders all current observability state as the metrics v2 JSON object.
pub fn metricsV2Value(allocator: std.mem.Allocator, state: State, base: BaseMetrics) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_metrics_v2" });
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
    try obj.put(allocator, "analysis_cache", try analysisCacheValue(allocator, base.analysis_cache));
    try obj.put(allocator, "artifact_registry", try artifactMetricsValue(allocator, base.artifacts));
    try obj.put(allocator, "zls_status", .{ .string = base.zls_status });
    try obj.put(allocator, "zls_restart_attempts", .{ .integer = @intCast(base.zls_restart_attempts) });
    try obj.put(allocator, "zls_last_failure", optionalString(base.zls_last_failure));
    try obj.put(allocator, "backend_health_history", try backendHistoryValue(allocator, state, base));
    try obj.put(allocator, "zls_timeline", try zlsTimelineValue(allocator, state, base));
    try obj.put(allocator, "tool_latency", try toolLatencyValue(allocator, state));
    try obj.put(allocator, "command_durations", try commandDurationsValue(allocator, state));
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
pub fn backendHistoryValue(allocator: std.mem.Allocator, state: State, base: BaseMetrics) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_backend_health_history" });
    try obj.put(allocator, "history_capacity", .{ .integer = max_backend_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(state.backend_event_count) });
    try obj.put(allocator, "events", try backendEventsValue(allocator, state));
    try obj.put(allocator, "current_probe_cache", try backendProbeCacheValue(allocator, base.backend_probe_cache));
    try obj.put(allocator, "resolution", .{ .string = "Call zigar_doctor with probe_backends=true to refresh optional backend health; this history records probes observed in the current server process." });
    return .{ .object = obj };
}

/// Renders bounded ZLS status transitions, or the current snapshot when empty.
pub fn zlsTimelineValue(allocator: std.mem.Allocator, state: State, base: BaseMetrics) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_zls_timeline" });
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
pub fn toolLatencyValue(allocator: std.mem.Allocator, state: State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_tool_latency" });
    try obj.put(allocator, "observed_tool_calls", .{ .integer = @intCast(state.total_tool_calls) });
    try obj.put(allocator, "observed_tool_errors", .{ .integer = @intCast(state.total_tool_errors) });
    try obj.put(allocator, "tool_count", .{ .integer = @intCast(state.tool_stat_count) });
    try obj.put(allocator, "tools", try toolStatsValue(allocator, state));
    try obj.put(allocator, "units", .{ .string = "milliseconds" });
    try obj.put(allocator, "resolution", .{ .string = "Latency is measured around MCP schema validation and handler dispatch inside the current zigar process." });
    return .{ .object = obj };
}

/// Renders bounded subprocess duration history.
pub fn commandDurationsValue(allocator: std.mem.Allocator, state: State) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_command_durations" });
    try obj.put(allocator, "history_capacity", .{ .integer = max_command_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(state.command_event_count) });
    try obj.put(allocator, "avg_duration_ms", .{ .integer = @intCast(if (state.command_event_count == 0) 0 else state.total_command_duration_ms / state.command_event_count) });
    try obj.put(allocator, "events", try commandEventsValue(allocator, state));
    try obj.put(allocator, "resolution", .{ .string = "Command durations are observed for commands routed through shared zigar command helpers in the current server process." });
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
    try obj.put(allocator, "resolution", .{ .string = "Use zigar_artifact_index for artifact paths, hashes, and provenance details." });
    return .{ .object = obj };
}

/// Builds a snapshot of tool invocation metrics.
fn toolStatsValue(allocator: std.mem.Allocator, state: State) !std.json.Value {
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
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

/// Builds a snapshot of backend event counters.
fn backendEventsValue(allocator: std.mem.Allocator, state: State) !std.json.Value {
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
fn commandEventsValue(allocator: std.mem.Allocator, state: State) !std.json.Value {
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

/// Builds a snapshot of ZLS event counters.
fn zlsEventsValue(allocator: std.mem.Allocator, state: State, base: BaseMetrics) !std.json.Value {
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
    try array.append(.{ .string = "In-memory metrics reset when the zigar process restarts." });
    try array.append(.{ .string = "Backend history records probes observed through shared probe helpers, not external backend state changes." });
    try array.append(.{ .string = "Command-duration history covers commands routed through shared zigar helpers; direct external process state is not inferred." });
    try array.append(.{ .string = "Latency is dispatch duration and does not include client/network serialization time." });
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
    return @intCast((sequence - 1) % capacity);
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

    const metrics = try metricsV2Value(allocator, state, base);
    try std.testing.expectEqualStrings("zigar_metrics_v2", metrics.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 3), metrics.object.get("observed_tool_calls").?.integer);

    const backend_history = try backendHistoryValue(allocator, state, base);
    try std.testing.expectEqual(@as(usize, 2), backend_history.object.get("events").?.array.items.len);

    const timeline = try zlsTimelineValue(allocator, state, base);
    try std.testing.expectEqualStrings("runtime_transition", timeline.object.get("events").?.array.items[0].object.get("source").?.string);

    const latency = try toolLatencyValue(allocator, state);
    const first_tool = latency.object.get("tools").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 500), first_tool.get("error_rate_per_1000").?.integer);

    const durations = try commandDurationsValue(allocator, state);
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

    const timeline = try zlsTimelineValue(allocator, .{}, base);
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

        if (metricsV2Value(allocator, state, base)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (backendHistoryValue(allocator, state, base)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (zlsTimelineValue(allocator, state, base)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (toolLatencyValue(allocator, state)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (commandDurationsValue(allocator, state)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (zlsTimelineValue(allocator, .{}, base)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (backendProbeCacheValue(allocator, base.backend_probe_cache)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (probeSnapshotValue(allocator, base.backend_probe_cache.zig)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (probeSnapshotValue(allocator, null)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        if (limitationsValue(allocator)) |_| {} else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}
