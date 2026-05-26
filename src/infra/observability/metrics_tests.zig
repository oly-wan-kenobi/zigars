const std = @import("std");
const observability = @import("state.zig");
const metrics = @import("metrics.zig");

const Reader = metrics.Reader;

fn snapshotWithAllocator(allocator: std.mem.Allocator) !void {
    var state = observability.State{};
    state.recordToolCall("zig_build", 4, false);
    state.recordCommand("zig build", &.{"zig"}, 11, true, null);
    state.recordBackendProbe("zls", true, "ok", "backend command completed");
    state.recordZlsStatus("connected", null, 0);

    var reader = Reader.init(&state);
    const snapshot_value = try reader.port().snapshot(allocator);
    defer snapshot_value.deinit(allocator);
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

test "reader snapshot cleans partial allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, snapshotWithAllocator, .{});
}
