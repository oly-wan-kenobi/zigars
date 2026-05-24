const std = @import("std");

const ports = @import("../../app/ports.zig");
const observability = @import("state.zig");

pub const Reader = struct {
    state: *observability.State,

    const Self = @This();

    pub fn init(state: *observability.State) Self {
        return .{ .state = state };
    }

    pub fn port(self: *Self) ports.ObservabilityReader {
        return .{
            .ptr = self,
            .vtable = &.{ .snapshot = snapshot },
        };
    }

    fn snapshot(ptr: *anyopaque, allocator: std.mem.Allocator) ports.PortError!ports.ObservabilitySnapshot {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const state = self.state.*;

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
            };
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

        return .{
            .tool_stats = tool_stats,
            .command_events = command_events,
            .backend_events = backend_events,
            .zls_events = zls_events,
            .total_tool_calls = state.total_tool_calls,
            .total_tool_errors = state.total_tool_errors,
            .total_command_duration_ms = state.total_command_duration_ms,
            .command_event_count = state.command_event_count,
            .backend_event_count = state.backend_event_count,
            .zls_event_count = state.zls_event_count,
            .owns_memory = true,
        };
    }
};

fn boundedLen(count: u64, capacity: usize) usize {
    return @intCast(@min(count, capacity));
}

fn firstSequence(count: u64, capacity: usize) u64 {
    if (count == 0) return 1;
    if (count <= capacity) return 1;
    return count - capacity + 1;
}

fn ringIndex(sequence: u64, comptime capacity: usize) usize {
    return @intCast((sequence - 1) % capacity);
}

test "reader returns bounded observability snapshots in chronological order" {
    var state = observability.State{};
    var i: usize = 0;
    while (i < observability.max_backend_events + 2) : (i += 1) {
        state.recordBackendProbe("zls", i % 2 == 0, "ok", "backend command completed");
    }
    state.recordToolCall("zig_build", 4, false);
    state.recordCommand("zig build", &.{ "zig", "build" }, 11, true, null);
    state.recordZlsStatus("connected", null, 0);

    var reader = Reader.init(&state);
    const snapshot_value = try reader.port().snapshot(std.testing.allocator);
    defer snapshot_value.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, observability.max_backend_events + 2), snapshot_value.backend_event_count);
    try std.testing.expectEqual(@as(usize, observability.max_backend_events), snapshot_value.backend_events.len);
    try std.testing.expectEqual(@as(u64, 3), snapshot_value.backend_events[0].sequence);
    try std.testing.expectEqualStrings("zig_build", snapshot_value.tool_stats[0].name);
    try std.testing.expectEqualStrings("zig build", snapshot_value.command_events[0].title);
    try std.testing.expectEqualStrings("connected", snapshot_value.zls_events[0].status);
}
