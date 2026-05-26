const std = @import("std");
const mcp = @import("mcp");

const app_context = @import("../../../app/context.zig");
const ports = @import("../../../app/ports.zig");
const read_model = @import("../../../app/usecases/observability/workflows.zig");
const mcp_result = @import("../result.zig");

pub fn zigarMetricsV2(
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

pub fn zigarBackendHealthHistory(
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

pub fn zigarZlsTimeline(
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

pub fn zigarToolLatency(
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

fn metricsV2Value(allocator: std.mem.Allocator, report: read_model.MetricsReport) !std.json.Value {
    const base = report.base;
    const observed = report.observed;
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
    try obj.put(allocator, "observed_tool_calls", .{ .integer = @intCast(observed.total_tool_calls) });
    try obj.put(allocator, "observed_tool_errors", .{ .integer = @intCast(observed.total_tool_errors) });
    try obj.put(allocator, "observed_tool_error_rate_per_1000", .{ .integer = @intCast(ratePerThousand(observed.total_tool_errors, observed.total_tool_calls)) });
    try obj.put(allocator, "analysis_cache", try analysisCacheValue(allocator, base.analysis_cache));
    try obj.put(allocator, "artifact_registry", try artifactMetricsValue(allocator, base.artifacts));
    try obj.put(allocator, "zls_status", .{ .string = base.zls_status });
    try obj.put(allocator, "zls_restart_attempts", .{ .integer = @intCast(base.zls_restart_attempts) });
    try obj.put(allocator, "zls_last_failure", optionalString(base.zls_last_failure));
    try obj.put(allocator, "backend_health_history", try backendHistoryValue(allocator, report));
    try obj.put(allocator, "zls_timeline", try zlsTimelineValue(allocator, report));
    try obj.put(allocator, "tool_latency", try toolLatencyValue(allocator, observed));
    try obj.put(allocator, "command_durations", try commandDurationsValue(allocator, observed));
    try obj.put(allocator, "limitations", try limitationsValue(allocator));
    return .{ .object = obj };
}

fn backendHistoryValue(allocator: std.mem.Allocator, report: read_model.MetricsReport) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_backend_health_history" });
    try obj.put(allocator, "history_capacity", .{ .integer = read_model.max_backend_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(report.observed.backend_event_count) });
    try obj.put(allocator, "events", try backendEventsValue(allocator, report.observed));
    try obj.put(allocator, "current_probe_cache", try backendCacheValue(allocator, report.base.backend_probe_cache));
    try obj.put(allocator, "resolution", .{ .string = "Call zigar_doctor with probe_backends=true to refresh optional backend health; this history records probes observed in the current server process." });
    return .{ .object = obj };
}

fn zlsTimelineValue(allocator: std.mem.Allocator, report: read_model.MetricsReport) !std.json.Value {
    const base = report.base;
    const observed = report.observed;
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_zls_timeline" });
    try obj.put(allocator, "history_capacity", .{ .integer = read_model.max_zls_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(observed.zls_event_count) });
    try obj.put(allocator, "current_status", .{ .string = base.zls_status });
    try obj.put(allocator, "current_failure", optionalString(base.zls_last_failure));
    try obj.put(allocator, "restart_attempts", .{ .integer = @intCast(base.zls_restart_attempts) });
    try obj.put(allocator, "events", try zlsEventsValue(allocator, observed, base));
    try obj.put(allocator, "timeline_clock", .{ .string = "monotonic_sequence" });
    return .{ .object = obj };
}

fn toolLatencyValue(allocator: std.mem.Allocator, snapshot: ports.ObservabilitySnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_tool_latency" });
    try obj.put(allocator, "observed_tool_calls", .{ .integer = @intCast(snapshot.total_tool_calls) });
    try obj.put(allocator, "observed_tool_errors", .{ .integer = @intCast(snapshot.total_tool_errors) });
    try obj.put(allocator, "tool_count", .{ .integer = @intCast(snapshot.tool_stats.len) });
    try obj.put(allocator, "tools", try toolStatsValue(allocator, snapshot.tool_stats));
    try obj.put(allocator, "units", .{ .string = "milliseconds" });
    try obj.put(allocator, "resolution", .{ .string = "Latency is measured around MCP schema validation and handler dispatch inside the current zigar process." });
    return .{ .object = obj };
}

fn commandDurationsValue(allocator: std.mem.Allocator, snapshot: ports.ObservabilitySnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "zigar_command_durations" });
    try obj.put(allocator, "history_capacity", .{ .integer = read_model.max_command_events });
    try obj.put(allocator, "recorded_events", .{ .integer = @intCast(snapshot.command_event_count) });
    try obj.put(allocator, "avg_duration_ms", .{ .integer = @intCast(if (snapshot.command_event_count == 0) 0 else snapshot.total_command_duration_ms / snapshot.command_event_count) });
    try obj.put(allocator, "events", try commandEventsValue(allocator, snapshot.command_events));
    try obj.put(allocator, "resolution", .{ .string = "Command durations are observed for commands routed through shared zigar command helpers in the current server process." });
    return .{ .object = obj };
}

fn analysisCacheValue(allocator: std.mem.Allocator, cache: read_model.AnalysisCacheSnapshot) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "present", .{ .bool = cache.present });
    try obj.put(allocator, "hits", .{ .integer = @intCast(cache.hits) });
    try obj.put(allocator, "refreshes", .{ .integer = @intCast(cache.refreshes) });
    try obj.put(allocator, "bytes", .{ .integer = @intCast(cache.bytes) });
    return .{ .object = obj };
}

fn artifactMetricsValue(allocator: std.mem.Allocator, metrics: read_model.ArtifactMetrics) !std.json.Value {
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

fn toolStatsValue(allocator: std.mem.Allocator, stats: []const ports.ObservabilityToolStats) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    for (stats) |stat| {
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

fn limitationsValue(allocator: std.mem.Allocator) !std.json.Value {
    var array = std.json.Array.init(allocator);
    errdefer array.deinit();
    try array.append(.{ .string = "In-memory metrics reset when the zigar process restarts." });
    try array.append(.{ .string = "Backend history records probes observed through shared probe helpers, not external backend state changes." });
    try array.append(.{ .string = "Command-duration history covers commands routed through shared zigar helpers; direct external process state is not inferred." });
    try array.append(.{ .string = "Latency is dispatch duration and does not include client/network serialization time." });
    return .{ .array = array };
}

fn optionalString(value: ?[]const u8) std.json.Value {
    return if (value) |text| .{ .string = text } else .null;
}

fn ratePerThousand(numerator: u64, denominator: u64) u64 {
    if (denominator == 0) return 0;
    return numerator * 1000 / denominator;
}

test "metrics v2 adapter exposes observed latency and backend history" {
    const TestContext = struct {
        var tool_stats = [_]ports.ObservabilityToolStats{
            .{ .name = "zig_version", .calls = 1, .total_latency_ms = 3, .max_latency_ms = 3, .last_latency_ms = 3 },
            .{ .name = "zig_check", .calls = 1, .errors = 1, .total_latency_ms = 9, .max_latency_ms = 9, .last_latency_ms = 9, .last_error = true },
        };
        var backend_events = [_]ports.ObservabilityBackendEvent{
            .{ .sequence = 1, .backend = "zls", .ok = true, .status = "ok", .resolution = "backend command completed" },
        };
        var zls_events = [_]ports.ObservabilityZlsEvent{
            .{ .sequence = 1, .status = "connected" },
        };

        fn snapshot(_: *anyopaque, _: std.mem.Allocator) ports.PortError!ports.ObservabilitySnapshot {
            return .{
                .tool_stats = tool_stats[0..],
                .backend_events = backend_events[0..],
                .zls_events = zls_events[0..],
                .total_tool_calls = 2,
                .total_tool_errors = 1,
                .backend_event_count = 1,
                .zls_event_count = 1,
            };
        }

        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return error.FileNotFound;
        }

        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        fn workspaceResolve(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
            return error.FileNotFound;
        }

        const observability_vtable = ports.ObservabilityReader.VTable{ .snapshot = snapshot };
        const workspace_vtable = ports.WorkspaceStore.VTable{
            .resolve = workspaceResolve,
            .read = workspaceRead,
            .write = workspaceWrite,
        };
    };

    var command_calls: usize = 2;
    var zls_requests: usize = 1;
    var tool_errors: usize = 0;
    var token: u8 = 0;
    const context: app_context.ObservabilityContext = .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .zls_state = .{ .status = "connected" },
        .counters = .{
            .command_calls = &command_calls,
            .zls_requests = &zls_requests,
            .tool_errors = &tool_errors,
        },
        .probe_cache = .{ .zls = .{ .probed = true, .ok = true, .status = "ok", .resolution = "backend command completed" } },
        .workspace_store = .{ .ptr = &token, .vtable = &TestContext.workspace_vtable },
        .observability_reader = .{ .ptr = &token, .vtable = &TestContext.observability_vtable },
    };

    const result = try zigarMetricsV2(std.testing.allocator, context, null);
    defer mcp_result.deinitToolResult(std.testing.allocator, result);

    const root = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigar_metrics_v2", root.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 2), root.get("observed_tool_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 1), root.get("observed_tool_errors").?.integer);
    try std.testing.expect(root.get("tool_latency").?.object.get("tools").?.array.items.len >= 2);
    try std.testing.expectEqual(@as(i64, 1), root.get("backend_health_history").?.object.get("recorded_events").?.integer);
    try std.testing.expectEqual(@as(i64, 1), root.get("zls_timeline").?.object.get("recorded_events").?.integer);

    const history = try zigarBackendHealthHistory(std.testing.allocator, context, null);
    defer mcp_result.deinitToolResult(std.testing.allocator, history);
    try std.testing.expectEqualStrings("zigar_backend_health_history", history.structuredContent.?.object.get("kind").?.string);

    const latency = try zigarToolLatency(std.testing.allocator, context, null);
    defer mcp_result.deinitToolResult(std.testing.allocator, latency);
    try std.testing.expectEqualStrings("zigar_tool_latency", latency.structuredContent.?.object.get("kind").?.string);

    const write_result = try context.workspace_store.write(.{ .path = ".zigar-cache/probe", .bytes = "ok", .provenance = "unit" });
    try std.testing.expectEqual(@as(usize, 2), write_result.bytes_written);
}

test "timeline adapter returns current snapshot without recorded transitions" {
    const TestContext = struct {
        fn snapshot(_: *anyopaque, _: std.mem.Allocator) ports.PortError!ports.ObservabilitySnapshot {
            return .{};
        }

        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return error.FileNotFound;
        }

        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        fn workspaceResolve(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
            return error.FileNotFound;
        }

        const observability_vtable = ports.ObservabilityReader.VTable{ .snapshot = snapshot };
        const workspace_vtable = ports.WorkspaceStore.VTable{
            .resolve = workspaceResolve,
            .read = workspaceRead,
            .write = workspaceWrite,
        };
    };

    var token: u8 = 0;
    const context: app_context.ObservabilityContext = .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .zls_state = .{ .status = "FileNotFound", .last_failure = "FileNotFound", .restart_attempts = 1 },
        .workspace_store = .{ .ptr = &token, .vtable = &TestContext.workspace_vtable },
        .observability_reader = .{ .ptr = &token, .vtable = &TestContext.observability_vtable },
    };

    const result = try zigarZlsTimeline(std.testing.allocator, context, null);
    defer mcp_result.deinitToolResult(std.testing.allocator, result);

    const root = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigar_zls_timeline", root.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 0), root.get("recorded_events").?.integer);
    const events = root.get("events").?.array;
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("current_snapshot", events.items[0].object.get("source").?.string);

    const write_result = try context.workspace_store.write(.{ .path = ".zigar-cache/probe", .bytes = "", .provenance = "unit" });
    try std.testing.expectEqual(@as(usize, 0), write_result.bytes_written);
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
        if (commandDurationsValue(allocator, snapshot)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        if (zlsEventsValue(allocator, .{}, report.base)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        if (backendCacheValue(allocator, report.base.backend_probe_cache)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
        if (limitationsValue(allocator)) |_| {} else |err| try std.testing.expect(err == error.OutOfMemory);
    }
}
