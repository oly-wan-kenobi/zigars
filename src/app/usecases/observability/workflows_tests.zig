const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const workflows = @import("workflows.zig");

/// Artifact scan limit applied when collecting workflow evidence.
const artifact_scan_limit = workflows.artifact_scan_limit;
const baseMetrics = workflows.baseMetrics;
const metricsReport = workflows.metricsReport;

test "metrics report combines counters, cache state, artifacts, and observed rings" {
    const Stub = struct {
        var tool_stats = [_]ports.ObservabilityToolStats{
            .{ .name = "zig_build", .calls = 2, .errors = 1, .total_latency_ms = 14, .max_latency_ms = 10, .last_latency_ms = 10, .last_error = true },
        };
        var commands = [_]ports.ObservabilityCommandEvent{
            .{ .sequence = 1, .title = "zig build", .argv0 = "zig", .duration_ms = 11, .ok = true },
        };

        /// Implements snapshot workflow logic using caller-owned inputs.
        fn snapshot(_: *anyopaque, _: std.mem.Allocator) ports.PortError!ports.ObservabilitySnapshot {
            return .{
                .tool_stats = tool_stats[0..],
                .command_events = commands[0..],
                .total_tool_calls = 2,
                .total_tool_errors = 1,
                .total_command_duration_ms = 11,
                .command_event_count = 1,
            };
        }

        /// Reads workspace fixture bytes for the requested path.
        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return error.FileNotFound;
        }

        /// Stores workspace fixture bytes for the requested path.
        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        /// Resolves a workspace-relative fixture path.
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

    var command_calls: usize = 3;
    var zls_requests: usize = 4;
    var tool_errors: usize = 5;
    var token: u8 = 0;
    const context: app_context.ObservabilityContext = .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .zls_state = .{ .status = "connected", .restart_attempts = 1 },
        .counters = .{
            .command_calls = &command_calls,
            .zls_requests = &zls_requests,
            .tool_errors = &tool_errors,
        },
        .caches = .{ .analysis = .{ .cached = true, .hits = 6, .refreshes = 7, .bytes = 8 } },
        .probe_cache = .{ .zls = .{ .probed = true, .ok = true, .status = "ok", .resolution = "backend command completed" } },
        .workspace_store = .{ .ptr = &token, .vtable = &Stub.workspace_vtable },
        .observability_reader = .{ .ptr = &token, .vtable = &Stub.observability_vtable },
    };

    const report = try metricsReport(std.testing.allocator, context);
    try std.testing.expectEqual(@as(usize, 3), report.base.command_calls);
    try std.testing.expectEqual(@as(usize, 8), report.base.analysis_cache.bytes);
    try std.testing.expectEqual(@as(u64, 2), report.observed.total_tool_calls);
    try std.testing.expectEqualStrings("zig_build", report.observed.tool_stats[0].name);
    try std.testing.expectEqualStrings("ok", report.base.backend_probe_cache.zls.?.status);
    try std.testing.expectEqualStrings("ok", report.base.artifacts.status);
    const write_result = try Stub.workspaceWrite(&token, .{ .path = ".zigar-cache/probe", .bytes = "ok" });
    try std.testing.expectEqual(@as(usize, 2), write_result.bytes_written);
}

test "base metrics reports artifact registry read failures" {
    const Stub = struct {
        /// Reads workspace fixture bytes for the requested path.
        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return error.AccessDenied;
        }

        /// Stores workspace fixture bytes for the requested path.
        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        /// Implements snapshot workflow logic using caller-owned inputs.
        fn snapshot(_: *anyopaque, _: std.mem.Allocator) ports.PortError!ports.ObservabilitySnapshot {
            return .{};
        }

        const workspace_vtable = ports.WorkspaceStore.VTable{
            .read = workspaceRead,
            .write = workspaceWrite,
        };
        const observability_vtable = ports.ObservabilityReader.VTable{ .snapshot = snapshot };
    };
    var token: u8 = 0;
    const context: app_context.ObservabilityContext = .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .zls_state = .{},
        .workspace_store = .{ .ptr = &token, .vtable = &Stub.workspace_vtable },
        .observability_reader = .{ .ptr = &token, .vtable = &Stub.observability_vtable },
    };

    const base = baseMetrics(std.testing.allocator, context);
    try std.testing.expectEqualStrings("AccessDenied", base.artifacts.status);

    const write_result = try Stub.workspaceWrite(&token, .{ .path = ".zigar-cache/probe", .bytes = "ok" });
    try std.testing.expectEqual(@as(usize, 2), write_result.bytes_written);
    const observed = try Stub.snapshot(&token, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), observed.total_tool_calls);
}

test "base metrics reports artifact scan failures" {
    const Stub = struct {
        var entries = [_]ports.WorkspaceDirectoryEntry{.{ .path = "report.log" }};

        /// Reads workspace fixture bytes for the requested path.
        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return error.FileNotFound;
        }

        /// Stores workspace fixture bytes for the requested path.
        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        /// Resolves a workspace-relative fixture path.
        fn workspaceResolve(_: *anyopaque, _: std.mem.Allocator, request: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
            return .{ .path = request.path };
        }

        /// Scans fixture workspace entries and returns matching paths.
        fn scanDirectory(_: *anyopaque, _: std.mem.Allocator, request: ports.WorkspaceDirectoryScanRequest) ports.PortError!ports.WorkspaceDirectoryScanResult {
            if (request.max_files != artifact_scan_limit) return error.UnexpectedCall;
            return .{ .entries = entries[0..] };
        }

        /// Implements snapshot workflow logic using caller-owned inputs.
        fn snapshot(_: *anyopaque, _: std.mem.Allocator) ports.PortError!ports.ObservabilitySnapshot {
            return .{};
        }

        const workspace_vtable = ports.WorkspaceStore.VTable{
            .resolve = workspaceResolve,
            .read = workspaceRead,
            .write = workspaceWrite,
            .scan_directory = scanDirectory,
        };
        const observability_vtable = ports.ObservabilityReader.VTable{ .snapshot = snapshot };
    };
    var token: u8 = 0;
    const context: app_context.ObservabilityContext = .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .zls_state = .{},
        .workspace_store = .{ .ptr = &token, .vtable = &Stub.workspace_vtable },
        .observability_reader = .{ .ptr = &token, .vtable = &Stub.observability_vtable },
    };

    var saw_scan_failure = false;
    for (0..16) |fail_index| {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        const base = baseMetrics(failing.allocator(), context);
        if (std.mem.eql(u8, base.artifacts.status, "OutOfMemory")) {
            saw_scan_failure = true;
            break;
        }
    }
    try std.testing.expect(saw_scan_failure);

    const write_result = try Stub.workspaceWrite(&token, .{ .path = ".zigar-cache/scan", .bytes = "ok" });
    try std.testing.expectEqual(@as(usize, 2), write_result.bytes_written);
    const observed = try Stub.snapshot(&token, std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 0), observed.total_tool_calls);
}
