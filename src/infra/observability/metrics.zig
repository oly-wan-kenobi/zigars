const std = @import("std");

const ports = @import("../../app/ports.zig");
const observability = @import("state.zig");

/// ObservabilityReader port that snapshots bounded in-memory metrics.
pub const Reader = struct {
    state: *observability.State,

    const Self = @This();

    /// Stores a borrowed pointer to process-local observability state.
    pub fn init(state: *observability.State) Self {
        return .{ .state = state };
    }

    /// Exposes this reader through the ObservabilityReader vtable.
    pub fn port(self: *Self) ports.ObservabilityReader {
        return .{
            .ptr = self,
            .vtable = &.{ .snapshot = snapshot },
        };
    }

    /// Returns an allocator-owned snapshot of recorded metrics.
    fn snapshot(ptr: *anyopaque, allocator: std.mem.Allocator) ports.PortError!ports.ObservabilitySnapshot {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const state = self.state.*;

        // Copy fixed metric slots and ring buffers into caller-owned slices so
        // the port result is stable after the state changes.
        const tool_stats = allocator.alloc(ports.ObservabilityToolStats, state.tool_stat_count) catch return error.OutOfMemory;
        errdefer allocator.free(tool_stats);
        for (state.tool_stats[0..state.tool_stat_count], 0..) |stat, index| {
            tool_stats[index] = .{
                .name = stat.name,
                .calls = stat.calls,
                .errors = stat.errors,
                .total_latency_ms = stat.total_latency_ms,
                .max_latency_ms = stat.max_latency_ms,
                .last_latency_ms = stat.last_latency_ms,
                .last_error = stat.last_error,
                .latency_samples = stat.latency.samples,
                .latency_sample_count = stat.latency.sample_count,
            };
        }

        const method_stats = allocator.alloc(ports.ObservabilityMethodStats, state.method_stat_count) catch return error.OutOfMemory;
        errdefer allocator.free(method_stats);
        for (state.method_stats[0..state.method_stat_count], 0..) |stat, index| {
            method_stats[index] = .{
                .name = stat.name,
                .name_len = stat.name_len,
                .name_truncated = stat.name_truncated,
                .calls = stat.calls,
                .errors = stat.errors,
                .total_latency_ms = stat.total_latency_ms,
                .max_latency_ms = stat.max_latency_ms,
                .last_latency_ms = stat.last_latency_ms,
                .last_error = stat.last_error,
                .latency_samples = stat.latency.samples,
                .latency_sample_count = stat.latency.sample_count,
            };
        }

        const correlation_len = boundedLen(state.tool_call_correlation_count, observability.max_tool_call_correlations);
        const tool_call_correlations = allocator.alloc(ports.ObservabilityToolCallCorrelation, correlation_len) catch return error.OutOfMemory;
        errdefer allocator.free(tool_call_correlations);
        var correlation_sequence = firstSequence(state.tool_call_correlation_count, observability.max_tool_call_correlations);
        for (tool_call_correlations) |*event| {
            const source = state.tool_call_correlations[ringIndex(correlation_sequence, observability.max_tool_call_correlations)];
            event.* = .{
                .sequence = source.sequence,
                .tool_name = source.tool_name,
                .is_error = source.is_error,
                .mcp_request_id_type = source.mcp_request_id_type,
                .mcp_request_id_value = source.mcp_request_id_value,
                .mcp_request_id_value_len = source.mcp_request_id_value_len,
                .mcp_request_id_truncated = source.mcp_request_id_truncated,
                .trace_id = source.trace_id,
                .span_id = source.span_id,
                .parent_span_id = source.parent_span_id,
                .tool_call_id = source.tool_call_id,
                .tool_call_id_len = source.tool_call_id_len,
            };
            correlation_sequence += 1;
        }

        const command_len = boundedLen(state.command_event_count, observability.max_command_events);
        const command_events = allocator.alloc(ports.ObservabilityCommandEvent, command_len) catch return error.OutOfMemory;
        errdefer allocator.free(command_events);
        var command_sequence = firstSequence(state.command_event_count, observability.max_command_events);
        for (command_events) |*event| {
            const source = state.command_events[ringIndex(command_sequence, observability.max_command_events)];
            event.* = .{
                .sequence = source.sequence,
                .title = source.title,
                .argv0 = source.argv0,
                .duration_ms = source.duration_ms,
                .ok = source.ok,
                .error_name = source.error_name,
            };
            command_sequence += 1;
        }

        const backend_len = boundedLen(state.backend_event_count, observability.max_backend_events);
        const backend_events = allocator.alloc(ports.ObservabilityBackendEvent, backend_len) catch return error.OutOfMemory;
        errdefer allocator.free(backend_events);
        var backend_sequence = firstSequence(state.backend_event_count, observability.max_backend_events);
        for (backend_events) |*event| {
            const source = state.backend_events[ringIndex(backend_sequence, observability.max_backend_events)];
            event.* = .{
                .sequence = source.sequence,
                .backend = source.name,
                .ok = source.ok,
                .status = source.status,
                .resolution = source.resolution,
            };
            backend_sequence += 1;
        }

        const zls_len = boundedLen(state.zls_event_count, observability.max_zls_events);
        const zls_events = allocator.alloc(ports.ObservabilityZlsEvent, zls_len) catch return error.OutOfMemory;
        errdefer allocator.free(zls_events);
        var zls_sequence = firstSequence(state.zls_event_count, observability.max_zls_events);
        for (zls_events) |*event| {
            const source = state.zls_events[ringIndex(zls_sequence, observability.max_zls_events)];
            event.* = .{
                .sequence = source.sequence,
                .status = source.status,
                .failure = source.failure,
                .restart_attempts = source.restart_attempts,
            };
            zls_sequence += 1;
        }

        const startup_len = boundedLen(state.startup_phase_count, observability.max_startup_phases);
        const startup_phases = allocator.alloc(ports.ObservabilityStartupPhase, startup_len) catch return error.OutOfMemory;
        errdefer allocator.free(startup_phases);
        var startup_sequence = firstSequence(state.startup_phase_count, observability.max_startup_phases);
        for (startup_phases) |*phase| {
            const source = state.startup_phases[ringIndex(startup_sequence, observability.max_startup_phases)];
            phase.* = .{
                .sequence = source.sequence,
                .name = source.name,
                .start_ms = source.start_ms,
                .duration_ms = source.duration_ms,
            };
            startup_sequence += 1;
        }

        const cancellation_len = boundedLen(state.cancellation_event_count, observability.max_cancellation_events);
        const cancellation_events = allocator.alloc(ports.ObservabilityCancellationEvent, cancellation_len) catch return error.OutOfMemory;
        errdefer allocator.free(cancellation_events);
        var cancellation_sequence = firstSequence(state.cancellation_event_count, observability.max_cancellation_events);
        for (cancellation_events) |*event| {
            const source = state.cancellation_events[ringIndex(cancellation_sequence, observability.max_cancellation_events)];
            event.* = .{
                .sequence = source.sequence,
                .status = source.status,
                .mcp_request_id_type = source.mcp_request_id_type,
                .mcp_request_id_value = source.mcp_request_id_value,
                .mcp_request_id_value_len = source.mcp_request_id_value_len,
                .mcp_request_id_truncated = source.mcp_request_id_truncated,
                .method = source.method,
                .method_len = source.method_len,
                .method_truncated = source.method_truncated,
            };
            cancellation_sequence += 1;
        }

        return .{
            .tool_stats = tool_stats,
            .method_stats = method_stats,
            .tool_call_correlations = tool_call_correlations,
            .command_events = command_events,
            .backend_events = backend_events,
            .zls_events = zls_events,
            .startup_phases = startup_phases,
            .cancellation_events = cancellation_events,
            .total_tool_calls = state.total_tool_calls,
            .total_tool_errors = state.total_tool_errors,
            .total_mcp_requests = state.total_mcp_requests,
            .total_mcp_request_errors = state.total_mcp_request_errors,
            .total_command_duration_ms = state.total_command_duration_ms,
            .command_latency_samples = state.command_latency.samples,
            .command_latency_sample_count = state.command_latency.sample_count,
            .tool_call_correlation_count = state.tool_call_correlation_count,
            .command_event_count = state.command_event_count,
            .backend_event_count = state.backend_event_count,
            .zls_event_count = state.zls_event_count,
            .startup_phase_count = state.startup_phase_count,
            .cancellation_event_count = state.cancellation_event_count,
            .audit_enabled = state.audit_enabled,
            .audit_mode = state.audit_mode,
            .audit_path = state.audit_path,
            .audit_records_written = state.audit_records_written,
            .audit_write_errors = state.audit_write_errors,
            .audit_last_error = state.audit_last_error,
            .cancellation_requested = state.cancellation_requested,
            .cancellation_unknown = state.cancellation_unknown,
            .cancellation_completed = state.cancellation_completed,
            .cancellation_uncancellable = state.cancellation_uncancellable,
            .owns_memory = true,
        };
    }
};

/// Returns the number of retained entries in a bounded ring buffer.
fn boundedLen(count: u64, capacity: usize) usize {
    const capacity_u64: u64 = @intCast(capacity);
    return @intCast(@min(count, capacity_u64));
}

/// Finds the first sequence number retained in a ring buffer.
fn firstSequence(count: u64, capacity: usize) u64 {
    const capacity_u64: u64 = @intCast(capacity);
    if (count == 0) return 1;
    if (count <= capacity_u64) return 1;
    return count - capacity_u64 + 1;
}

/// Maps a sequence number to its ring-buffer index.
fn ringIndex(sequence: u64, comptime capacity: usize) usize {
    return @intCast((sequence - 1) % @as(u64, capacity));
}
