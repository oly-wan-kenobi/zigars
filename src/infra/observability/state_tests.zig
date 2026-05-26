const std = @import("std");
const observability = @import("state.zig");

test "tool latency stats aggregate calls and errors" {
    var state = observability.State{};
    state.recordToolCall("zig_build", 4, false);
    state.recordToolCall("zig_build", 10, true);
    state.recordToolCall("zig_check", 3, false);
    state.recordCommand("zig build", &.{ "zig", "build" }, 11, true, null);

    const value = try observability.toolLatencyValue(std.testing.allocator, state);
    defer {
        var root = value.object;
        var tools = root.get("tools").?.array;
        for (tools.items) |item| {
            var obj = item.object;
            obj.deinit(std.testing.allocator);
        }
        tools.deinit();
        root.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(i64, 3), value.object.get("observed_tool_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("observed_tool_errors").?.integer);
    const first = value.object.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("zig_build", first.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 2), first.get("calls").?.integer);
    try std.testing.expectEqual(@as(i64, 7), first.get("avg_latency_ms").?.integer);
    try std.testing.expectEqual(@as(i64, 10), first.get("max_latency_ms").?.integer);

    const command_value = try observability.commandDurationsValue(std.testing.allocator, state);
    defer {
        var root = command_value.object;
        var events = root.get("events").?.array;
        for (events.items) |item| {
            var obj = item.object;
            obj.deinit(std.testing.allocator);
        }
        events.deinit();
        root.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(i64, 1), command_value.object.get("recorded_events").?.integer);
    try std.testing.expectEqual(@as(i64, 11), command_value.object.get("avg_duration_ms").?.integer);
}

test "backend and zls histories keep chronological bounded events" {
    var state = observability.State{};
    var i: usize = 0;
    while (i < observability.max_backend_events + 2) : (i += 1) {
        state.recordBackendProbe("zls", i % 2 == 0, "ok", "backend command completed");
    }
    state.recordZlsStatus("not started", null, 0);
    state.recordZlsStatus("connected", null, 0);
    state.recordZlsStatus("FileNotFound", "FileNotFound", 1);

    const base: observability.BaseMetrics = .{
        .workspace = "/tmp/project",
        .command_calls = 0,
        .zls_requests = 0,
        .tool_errors = 0,
        .zls_status = "FileNotFound",
        .zls_last_failure = "FileNotFound",
        .zls_restart_attempts = 1,
        .backend_probe_cache = .{},
        .analysis_cache = .{},
        .artifacts = .{},
    };

    const backend_value = try observability.backendHistoryValue(std.testing.allocator, state, base);
    defer {
        var root = backend_value.object;
        var events = root.get("events").?.array;
        for (events.items) |item| {
            var obj = item.object;
            obj.deinit(std.testing.allocator);
        }
        events.deinit();
        var cache = root.get("current_probe_cache").?.object;
        var cache_it = cache.iterator();
        while (cache_it.next()) |entry| {
            var probe = entry.value_ptr.object;
            probe.deinit(std.testing.allocator);
        }
        cache.deinit(std.testing.allocator);
        root.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(i64, observability.max_backend_events + 2), backend_value.object.get("recorded_events").?.integer);
    try std.testing.expectEqual(@as(usize, observability.max_backend_events), backend_value.object.get("events").?.array.items.len);
    try std.testing.expectEqual(@as(i64, 3), backend_value.object.get("events").?.array.items[0].object.get("sequence").?.integer);

    const zls_value = try observability.zlsTimelineValue(std.testing.allocator, state, base);
    defer {
        var root = zls_value.object;
        var events = root.get("events").?.array;
        for (events.items) |item| {
            var obj = item.object;
            obj.deinit(std.testing.allocator);
        }
        events.deinit();
        root.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(i64, 3), zls_value.object.get("recorded_events").?.integer);
    try std.testing.expectEqualStrings("connected", zls_value.object.get("events").?.array.items[1].object.get("status").?.string);
}
