const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const common = @import("common.zig");

const App = common.App;
const observability = zigar.observability;
const structured = common.structured;

const artifacts = zigar.artifacts;
const artifact_scan_limit: usize = 500;
const artifact_scan_roots = [_][]const u8{ ".zigar-cache", "zig-out", "coverage", "dist" };

pub fn zigarMetricsV2(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, observability.metricsV2Value(allocator, a.observability, baseMetrics(a, allocator)) catch return error.OutOfMemory);
}

pub fn zigarBackendHealthHistory(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, observability.backendHistoryValue(allocator, a.observability, baseMetrics(a, allocator)) catch return error.OutOfMemory);
}

pub fn zigarZlsTimeline(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, observability.zlsTimelineValue(allocator, a.observability, baseMetrics(a, allocator)) catch return error.OutOfMemory);
}

pub fn zigarToolLatency(a: *App, allocator: std.mem.Allocator, _: ?std.json.Value) mcp.tools.ToolError!mcp.tools.ToolResult {
    return structured(allocator, observability.toolLatencyValue(allocator, a.observability) catch return error.OutOfMemory);
}

fn baseMetrics(a: *App, allocator: std.mem.Allocator) observability.BaseMetrics {
    return .{
        .workspace = a.workspace.root,
        .command_calls = a.command_calls,
        .zls_requests = a.zls_requests,
        .tool_errors = a.tool_errors,
        .zls_status = a.zls_status,
        .zls_last_failure = a.zls_last_failure,
        .zls_restart_attempts = a.zls_restart_attempts,
        .backend_probe_cache = .{
            .zig = probeSnapshot(a.backend_probe_cache.zig),
            .zls = probeSnapshot(a.backend_probe_cache.zls),
            .zwanzig = probeSnapshot(a.backend_probe_cache.zwanzig),
            .zflame = probeSnapshot(a.backend_probe_cache.zflame),
            .diff_folded = probeSnapshot(a.backend_probe_cache.diff_folded),
        },
        .analysis_cache = .{
            .present = a.analysis_cache.index_json != null,
            .hits = a.analysis_cache.hits,
            .refreshes = a.analysis_cache.refreshes,
            .bytes = if (a.analysis_cache.index_json) |bytes| bytes.len else 0,
        },
        .artifacts = artifactMetrics(a, allocator),
    };
}

fn artifactMetrics(a: *App, allocator: std.mem.Allocator) observability.ArtifactMetrics {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    var out: observability.ArtifactMetrics = .{ .scan_limit = artifact_scan_limit };
    const registry_abs = a.workspace.resolveOutput(artifacts.default_registry_path) catch |err| {
        out.status = @errorName(err);
        return out;
    };
    defer a.workspace.allocator.free(registry_abs);
    var registry = artifacts.loadRegistry(scratch, a.io, registry_abs) catch |err| {
        out.status = @errorName(err);
        return out;
    };
    defer registry.deinit(scratch);
    out.registry_available = registry.entries.items.len > 0;
    out.registry_entries = registry.entries.items.len;

    for (artifact_scan_roots) |root| {
        if (out.scanned_artifacts >= artifact_scan_limit) break;
        const resolved = a.workspace.resolve(root) catch continue;
        defer a.workspace.allocator.free(resolved);
        out.scanned_artifacts += countFilesBounded(scratch, a, resolved, artifact_scan_limit - out.scanned_artifacts) catch continue;
    }
    out.status = if (out.scanned_artifacts >= artifact_scan_limit) "scan_limit_reached" else "ok";
    return out;
}

fn countFilesBounded(allocator: std.mem.Allocator, a: *App, abs_root: []const u8, remaining: usize) !usize {
    var dir = std.Io.Dir.openDirAbsolute(a.io, abs_root, .{ .iterate = true }) catch return 0;
    defer dir.close(a.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var count: usize = 0;
    while (count < remaining) {
        const entry = walker.next(a.io) catch break;
        const actual = entry orelse break;
        if (actual.kind == .file) count += 1;
    }
    return count;
}

fn probeSnapshot(probe: ?zigar.doctor.Probe) ?observability.ProbeSnapshot {
    return if (probe) |p| .{
        .ok = p.ok,
        .status = p.status,
        .resolution = p.resolution,
    } else null;
}

test "metrics v2 handler exposes observed latency and backend history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = testApp();
    app.command_calls = 2;
    app.zls_requests = 1;
    app.zls_status = "connected";
    app.backend_probe_cache.zls = .{ .ok = true, .status = "ok", .resolution = "backend command completed" };
    app.observability.recordToolCall("zig_version", 3, false);
    app.observability.recordToolCall("zig_check", 9, true);
    app.observability.recordBackendProbe("zls", true, "ok", "backend command completed");
    app.observability.recordZlsStatus("connected", null, 0);

    const result = try zigarMetricsV2(&app, allocator, null);
    defer zigar.json_result.deinitToolResult(allocator, result);

    const root = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigar_metrics_v2", root.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 2), root.get("observed_tool_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 1), root.get("observed_tool_errors").?.integer);
    try std.testing.expect(root.get("tool_latency").?.object.get("tools").?.array.items.len >= 2);
    try std.testing.expectEqual(@as(i64, 1), root.get("backend_health_history").?.object.get("recorded_events").?.integer);
    try std.testing.expectEqual(@as(i64, 1), root.get("zls_timeline").?.object.get("recorded_events").?.integer);
}

test "timeline handler returns current snapshot without recorded transitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = testApp();
    app.zls_status = "FileNotFound";
    app.zls_last_failure = "FileNotFound";
    app.zls_restart_attempts = 1;

    const result = try zigarZlsTimeline(&app, allocator, null);
    defer zigar.json_result.deinitToolResult(allocator, result);

    const root = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigar_zls_timeline", root.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 0), root.get("recorded_events").?.integer);
    const events = root.get("events").?.array;
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("current_snapshot", events.items[0].object.get("source").?.string);
}

fn testApp() App {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .config = .{ .workspace = "/tmp/zigar-observability-test" },
        .workspace = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .root = "/tmp/zigar-observability-test",
            .cache_root = "/tmp/zigar-observability-test/.zigar-cache",
        },
    };
}
