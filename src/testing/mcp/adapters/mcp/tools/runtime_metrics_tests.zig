//! Tests for the runtime_metrics MCP tool adapter.
//! Pins the structured output shape for zigars_metrics_v2, backend health
//! history, tool latency, and ZLS timeline projections.
//! Uses in-process vtable fakes so no external backends are required.

const std = @import("std");

const app_context = @import("../../../../../app/context.zig");
const ports = @import("../../../../../app/ports.zig");
const mcp_result = @import("../../../../../adapters/mcp/result.zig");
const runtime_metrics = @import("../../../../../adapters/mcp/tools/runtime_metrics.zig");

test "metrics v2 adapter exposes observed latency and backend history" {
    // Static var fields allow the vtable fn pointers to capture fixture data
    // without an extra allocation; the test is single-threaded so this is safe.
    const TestContext = struct {
        var tool_stats = [_]ports.ObservabilityToolStats{
            .{ .name = "zig_version", .calls = 1, .total_latency_ms = 3, .max_latency_ms = 3, .last_latency_ms = 3 },
            .{ .name = "zig_check", .calls = 1, .errors = 1, .total_latency_ms = 9, .max_latency_ms = 9, .last_latency_ms = 9, .last_error = true },
        };
        var tool_call_correlations = [_]ports.ObservabilityToolCallCorrelation{
            .{
                .sequence = 1,
                .tool_name = "zig_check",
                .is_error = true,
                .mcp_request_id_type = "integer",
                .mcp_request_id_value = requestIdValue("42"),
                .mcp_request_id_value_len = 2,
                .trace_id = fixedTrace("00000000000000000000000000000042"),
                .span_id = fixedSpan("0000000000000042"),
                .tool_call_id = fixedToolCallId("zigars-tc-000000000042"),
                .tool_call_id_len = 22,
            },
        };
        var backend_events = [_]ports.ObservabilityBackendEvent{
            .{ .sequence = 1, .backend = "zls", .ok = true, .status = "ok", .resolution = "backend command completed" },
        };
        var zls_events = [_]ports.ObservabilityZlsEvent{
            .{ .sequence = 1, .status = "connected" },
        };

        fn snapshot(_: *anyopaque, _: std.mem.Allocator) ports.PortError!ports.ObservabilitySnapshot {
            // Keep this logic centralized so callers observe one consistent behavior path.
            return .{
                .tool_stats = tool_stats[0..],
                .tool_call_correlations = tool_call_correlations[0..],
                .backend_events = backend_events[0..],
                .zls_events = zls_events[0..],
                .total_tool_calls = 2,
                .total_tool_errors = 1,
                .tool_call_correlation_count = 1,
                .backend_event_count = 1,
                .zls_event_count = 1,
            };
        }

        fn requestIdValue(comptime value: []const u8) [ports.max_observability_request_id_value_len]u8 {
            var out = [_]u8{0} ** ports.max_observability_request_id_value_len;
            @memcpy(out[0..value.len], value);
            return out;
        }

        fn fixedTrace(comptime value: []const u8) [32]u8 {
            var out: [32]u8 = undefined;
            @memcpy(out[0..], value);
            return out;
        }

        fn fixedSpan(comptime value: []const u8) [16]u8 {
            var out: [16]u8 = undefined;
            @memcpy(out[0..], value);
            return out;
        }

        fn fixedToolCallId(comptime value: []const u8) [22]u8 {
            var out: [22]u8 = undefined;
            @memcpy(out[0..], value);
            return out;
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
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
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

    const result = try runtime_metrics.zigarsMetricsV2(std.testing.allocator, context, null);
    defer mcp_result.deinitToolResult(std.testing.allocator, result);

    const root = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigars_metrics_v2", root.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 2), root.get("observed_tool_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 1), root.get("observed_tool_errors").?.integer);
    try std.testing.expect(root.get("tool_latency").?.object.get("tools").?.array.items.len >= 2);
    try std.testing.expectEqual(@as(i64, 1), root.get("tool_latency").?.object.get("recorded_correlations").?.integer);
    const correlation = root.get("tool_latency").?.object.get("recent_tool_call_correlations").?.array.items[0].object;
    try std.testing.expectEqualStrings("zigars-tc-000000000042", correlation.get("tool_call_id").?.string);
    try std.testing.expectEqual(@as(i64, 1), root.get("backend_health_history").?.object.get("recorded_events").?.integer);
    try std.testing.expectEqual(@as(i64, 1), root.get("zls_timeline").?.object.get("recorded_events").?.integer);

    const history = try runtime_metrics.zigarsBackendHealthHistory(std.testing.allocator, context, null);
    defer mcp_result.deinitToolResult(std.testing.allocator, history);
    try std.testing.expectEqualStrings("zigars_backend_health_history", history.structuredContent.?.object.get("kind").?.string);

    const latency = try runtime_metrics.zigarsToolLatency(std.testing.allocator, context, null);
    defer mcp_result.deinitToolResult(std.testing.allocator, latency);
    try std.testing.expectEqualStrings("zigars_tool_latency", latency.structuredContent.?.object.get("kind").?.string);

    const write_result = try context.workspace_store.write(.{ .path = ".zigars-cache/probe", .bytes = "ok", .provenance = "unit" });
    try std.testing.expectEqual(@as(usize, 2), write_result.bytes_written);
}

test "timeline adapter returns current snapshot without recorded transitions" {
    // Empty snapshot simulates a fresh server that has never observed ZLS events.
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
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .zls_state = .{ .status = "FileNotFound", .last_failure = "FileNotFound", .restart_attempts = 1 },
        .workspace_store = .{ .ptr = &token, .vtable = &TestContext.workspace_vtable },
        .observability_reader = .{ .ptr = &token, .vtable = &TestContext.observability_vtable },
    };

    const result = try runtime_metrics.zigarsZlsTimeline(std.testing.allocator, context, null);
    defer mcp_result.deinitToolResult(std.testing.allocator, result);

    const root = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigars_zls_timeline", root.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 0), root.get("recorded_events").?.integer);
    const events = root.get("events").?.array;
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("current_snapshot", events.items[0].object.get("source").?.string);

    const write_result = try context.workspace_store.write(.{ .path = ".zigars-cache/probe", .bytes = "", .provenance = "unit" });
    try std.testing.expectEqual(@as(usize, 0), write_result.bytes_written);
}
