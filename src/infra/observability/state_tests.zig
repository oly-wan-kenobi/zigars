const std = @import("std");
const observability = @import("state.zig");
const render = @import("state_render.zig");

test "tool latency stats aggregate calls and errors" {
    var state = observability.State{};
    state.recordToolCall("zig_build", 4, false);
    state.recordToolCall("zig_build", 10, true);
    state.recordToolCall("zig_check", 3, false);
    state.recordCommand("zig build", &.{ "zig", "build" }, 11, true, null);

    const value = try render.toolLatencyValue(std.testing.allocator, &state);
    defer {
        var root = value.object;
        var tools = root.get("tools").?.array;
        for (tools.items) |item| {
            var obj = item.object;
            var percentiles = obj.get("latency_percentiles").?.object;
            percentiles.deinit(std.testing.allocator);
            obj.deinit(std.testing.allocator);
        }
        tools.deinit();
        var correlations = root.get("recent_tool_call_correlations").?.array;
        correlations.deinit();
        root.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(i64, 3), value.object.get("observed_tool_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 1), value.object.get("observed_tool_errors").?.integer);
    const first = value.object.get("tools").?.array.items[0].object;
    try std.testing.expectEqualStrings("zig_build", first.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 2), first.get("calls").?.integer);
    try std.testing.expectEqual(@as(i64, 7), first.get("avg_latency_ms").?.integer);
    try std.testing.expectEqual(@as(i64, 10), first.get("max_latency_ms").?.integer);

    const command_value = try render.commandDurationsValue(std.testing.allocator, &state);
    defer {
        var root = command_value.object;
        var percentiles = root.get("latency_percentiles").?.object;
        percentiles.deinit(std.testing.allocator);
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

    const base: render.BaseMetrics = .{
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

    const backend_value = try render.backendHistoryValue(std.testing.allocator, &state, base);
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

    const zls_value = try render.zlsTimelineValue(std.testing.allocator, &state, base);
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

test "rendered metrics include populated rings and current zls snapshot fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = observability.State{};
    state.recordToolCall("zig_version", 10, false);
    state.recordToolCall("zig_version", 20, true);
    state.recordBackendProbe("zig", true, "ok", "backend command completed");
    state.recordCommand("empty argv", &.{}, -1, false, "Timeout");
    state.recordZlsStatus("failed", "FileNotFound", 1);

    const base: render.BaseMetrics = .{
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

    const metrics = try render.metricsV2Value(allocator, &state, base);
    try std.testing.expectEqualStrings("zigars_metrics_v2", metrics.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 2), metrics.object.get("observed_tool_calls").?.integer);

    const durations = try render.commandDurationsValue(allocator, &state);
    const command = durations.object.get("events").?.array.items[0].object;
    try std.testing.expectEqualStrings("", command.get("argv0").?.string);
    try std.testing.expectEqualStrings("Timeout", command.get("error").?.string);

    const empty_state = observability.State{};
    const timeline = try render.zlsTimelineValue(allocator, &empty_state, base);
    const event = timeline.object.get("events").?.array.items[0].object;
    try std.testing.expectEqual(@as(i64, 0), event.get("sequence").?.integer);
    try std.testing.expectEqualStrings("current_snapshot", event.get("source").?.string);
}

test "retention metrics report capacity drops and truncated identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var state = observability.State{};
    var tool_names: [observability.max_tool_stats + 1][16]u8 = undefined;
    for (tool_names[0..], 0..) |*buffer, index| {
        const name = try std.fmt.bufPrint(buffer, "tool_{d}", .{index});
        state.recordToolCall(name, 1, false);
    }
    const long_request_id: [observability.max_request_id_value_len + 8]u8 = [_]u8{'r'} ** (observability.max_request_id_value_len + 8);
    state.recordToolCallWithCorrelation("tool_0", 2, false, .{
        .mcp_request_id_type = "string",
        .mcp_request_id_value = long_request_id[0..],
        .trace_id = "0123456789abcdef0123456789abcdef",
        .span_id = "0123456789abcdef",
        .tool_call_id = "tool-call-id-longer-than-twenty-two",
    });

    const long_method: [80]u8 = [_]u8{'m'} ** 80;
    state.recordMcpRequest(long_method[0..], 1, false);
    var method_names: [observability.max_method_stats][20]u8 = undefined;
    for (method_names[0..], 0..) |*buffer, index| {
        const name = try std.fmt.bufPrint(buffer, "method/{d}", .{index});
        state.recordMcpRequest(name, 1, false);
    }
    state.recordCancellation("unknown", "string", long_request_id[0..], long_method[0..]);

    const tool_latency = try render.toolLatencyValue(allocator, &state);
    try std.testing.expectEqual(@as(i64, 1), tool_latency.object.get("dropped_tool_stat_observations").?.integer);
    try std.testing.expectEqual(@as(i64, 1), tool_latency.object.get("truncated_request_id_values").?.integer);
    try std.testing.expect(tool_latency.object.get("recent_tool_call_correlations").?.array.items[0].object.get("tool_call_id_truncated").?.bool);

    const method_latency = try render.methodLatencyValue(allocator, &state);
    try std.testing.expectEqual(@as(i64, 1), method_latency.object.get("dropped_method_stat_observations").?.integer);
    try std.testing.expectEqual(@as(i64, 1), method_latency.object.get("truncated_method_names").?.integer);

    const cancellation = try render.cancellationValue(allocator, &state);
    try std.testing.expectEqual(@as(i64, 1), cancellation.object.get("truncated_request_id_values").?.integer);
    try std.testing.expectEqual(@as(i64, 1), cancellation.object.get("truncated_methods").?.integer);

    const retention = try render.retentionValue(allocator, &state);
    try std.testing.expectEqual(@as(i64, 1), retention.object.get("dropped_tool_stat_observations").?.integer);
    try std.testing.expectEqual(@as(i64, 1), retention.object.get("truncated_cancellation_methods").?.integer);
}
