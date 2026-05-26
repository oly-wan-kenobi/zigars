const std = @import("std");

const app_context = @import("../../../../../app/context.zig");
const ports = @import("../../../../../app/ports.zig");
const mcp_result = @import("../../../../../adapters/mcp/result.zig");
const runtime_metrics = @import("../../../../../adapters/mcp/tools/runtime_metrics.zig");

test "metrics v2 adapter exposes observed latency and backend history" {
    // Fixture context shared by related test cases.
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

    const result = try runtime_metrics.zigarMetricsV2(std.testing.allocator, context, null);
    defer mcp_result.deinitToolResult(std.testing.allocator, result);

    const root = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigar_metrics_v2", root.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 2), root.get("observed_tool_calls").?.integer);
    try std.testing.expectEqual(@as(i64, 1), root.get("observed_tool_errors").?.integer);
    try std.testing.expect(root.get("tool_latency").?.object.get("tools").?.array.items.len >= 2);
    try std.testing.expectEqual(@as(i64, 1), root.get("backend_health_history").?.object.get("recorded_events").?.integer);
    try std.testing.expectEqual(@as(i64, 1), root.get("zls_timeline").?.object.get("recorded_events").?.integer);

    const history = try runtime_metrics.zigarBackendHealthHistory(std.testing.allocator, context, null);
    defer mcp_result.deinitToolResult(std.testing.allocator, history);
    try std.testing.expectEqualStrings("zigar_backend_health_history", history.structuredContent.?.object.get("kind").?.string);

    const latency = try runtime_metrics.zigarToolLatency(std.testing.allocator, context, null);
    defer mcp_result.deinitToolResult(std.testing.allocator, latency);
    try std.testing.expectEqualStrings("zigar_tool_latency", latency.structuredContent.?.object.get("kind").?.string);

    const write_result = try context.workspace_store.write(.{ .path = ".zigar-cache/probe", .bytes = "ok", .provenance = "unit" });
    try std.testing.expectEqual(@as(usize, 2), write_result.bytes_written);
}

test "timeline adapter returns current snapshot without recorded transitions" {
    // Fixture context shared by related test cases.
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

    const result = try runtime_metrics.zigarZlsTimeline(std.testing.allocator, context, null);
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
