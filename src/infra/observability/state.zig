//! Process-local observability state: bounded rings and saturating counters for
//! tool calls, MCP requests, commands, backend probes, ZLS transitions, startup
//! phases, cancellations, and audit accounting.  No allocation; all state fits
//! in fixed-size arrays.  stdout is never written; this module is metrics-only.

const std = @import("std");
const ports = @import("../../app/ports.zig");

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
/// Samples are stored as a circular ring; once `max_latency_samples` are
/// recorded the ring overwrites the oldest entry.  `sample_count` continues
/// to increment beyond the ring capacity so callers can detect eviction.
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
/// `name` is a borrowed slice from the call site; tool names are expected to be
/// static string literals with process lifetime.
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
/// The method name is stored inline in a fixed-length buffer; names longer than
/// 64 bytes are truncated and `name_truncated` is set.
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
/// All slices are borrowed; the caller retains ownership.  Fields are copied
/// into the fixed-size `ToolCallCorrelation` ring entry during recording.
pub const ToolCallCorrelationInput = struct {
    mcp_request_id_type: []const u8 = "null",
    mcp_request_id_value: ?[]const u8 = null,
    trace_id: []const u8 = "",
    span_id: []const u8 = "",
    parent_span_id: ?[]const u8 = null,
    tool_call_id: []const u8 = "",
};

/// Bounded process-local correlation event for one MCP tools/call response.
/// Fields are stored inline with fixed capacities; values exceeding those
/// capacities are truncated and the corresponding `_truncated` flag is set.
/// `trace_id` and `span_id` are zero-padded to their full widths (32 and 16).
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
/// Zero-initializable; all fields have sensible defaults.  Not thread-safe by
/// itself; callers that mutate state from multiple threads must add their own
/// synchronization (the MCP adapter does this via the recorder port).
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
    /// The most recent error name is retained; earlier failures are overwritten.
    pub fn recordAuditWriteError(self: *State, err_name: []const u8) void {
        self.audit_write_errors +|= 1;
        self.audit_last_error = err_name;
    }

    /// Records an inbound cancellation notification outcome.
    /// `status` is one of: "unknown", "completed", "completed_late",
    /// "uncancellable", "not_cancellable".  Unrecognised values only increment
    /// `cancellation_requested`; the named counters are unaffected.
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
    /// Deduplication keeps the timeline readable when the LSP client emits
    /// repeated status notifications for the same state (e.g. keep-alive pings).
    pub fn recordZlsStatus(self: *State, status: []const u8, failure: ?[]const u8, restart_attempts: u64) void {
        if (self.zls_event_count > 0) {
            // Compare against the most-recently written ring slot, not sequence 1,
            // so the dedup check works correctly when the ring has wrapped.
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
    /// Returns null once `max_tool_stats` distinct names have been seen; the
    /// caller increments `dropped_tool_stat_observations` in that case.
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

    /// Returns the mutable metrics slot for an MCP method name, allocating a
    /// new slot on first use.  Truncated names are matched by prefix against
    /// the stored prefix so they do not collide with a distinct short name.
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

    /// Projects this state as the app-side observability recorder port. The MCP
    /// adapter holds only the port and never imports this infra module.
    pub fn recorder(self: *State) ports.ObservabilityRecorder {
        return .{ .ptr = self, .vtable = &recorder_vtable };
    }

    const recorder_vtable: ports.ObservabilityRecorder.VTable = .{
        .record_mcp_request = recorderRecordMcpRequest,
        .record_cancellation = recorderRecordCancellation,
        .record_startup_phase = recorderRecordStartupPhase,
        .record_audit_write_ok = recorderRecordAuditWriteOk,
        .record_audit_write_error = recorderRecordAuditWriteError,
    };

    fn recorderRecordMcpRequest(ptr: *anyopaque, method: []const u8, latency_ms: u64, is_error: bool) void {
        recorderState(ptr).recordMcpRequest(method, latency_ms, is_error);
    }

    fn recorderRecordCancellation(ptr: *anyopaque, status: []const u8, request_id_type: []const u8, request_id_value: ?[]const u8, method: ?[]const u8) void {
        recorderState(ptr).recordCancellation(status, request_id_type, request_id_value, method);
    }

    fn recorderRecordStartupPhase(ptr: *anyopaque, name: []const u8, start_ms: u64, duration_ms: u64) void {
        recorderState(ptr).recordStartupPhase(name, start_ms, duration_ms);
    }

    fn recorderRecordAuditWriteOk(ptr: *anyopaque) void {
        recorderState(ptr).recordAuditWriteOk();
    }

    fn recorderRecordAuditWriteError(ptr: *anyopaque, err_name: []const u8) void {
        recorderState(ptr).recordAuditWriteError(err_name);
    }

    fn recorderState(ptr: *anyopaque) *State {
        return @ptrCast(@alignCast(ptr));
    }
};

/// Compares optional string by the fields that affect behavior.
fn optionalStringEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

/// Matches method stats by full name, or by retained prefix when truncated.
/// Prefix matching prevents long method names from creating spurious new slots
/// after their truncated counterpart has already been recorded.
fn methodNameMatches(stat: *const MethodStats, name: []const u8) bool {
    const retained = stat.nameSlice();
    if (!stat.name_truncated) return std.mem.eql(u8, retained, name);
    return name.len >= retained.len and std.mem.eql(u8, retained, name[0..retained.len]);
}

/// Maps a 1-based sequence number to its ring-buffer storage index.
fn ringIndex(sequence: u64, comptime capacity: usize) usize {
    return @intCast((sequence - 1) % @as(u64, capacity));
}

/// Copies up to `dest.len` bytes from `source` into `dest`, padding the
/// remainder with `pad`.  Used to populate fixed-width ID fields.
fn copyFixed(dest: []u8, source: []const u8, pad: u8) void {
    const copy_len = @min(dest.len, source.len);
    @memcpy(dest[0..copy_len], source[0..copy_len]);
    if (copy_len < dest.len) @memset(dest[copy_len..], pad);
}
