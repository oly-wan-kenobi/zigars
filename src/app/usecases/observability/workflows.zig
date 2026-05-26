const std = @import("std");

const app_context = @import("../../context.zig");
const artifact_registry = @import("../artifacts/registry.zig");
const ports = @import("../../ports.zig");

pub const max_tool_stats = ports.max_observability_tool_stats;
pub const max_command_events = ports.max_observability_command_events;
pub const max_backend_events = ports.max_observability_backend_events;
pub const max_zls_events = ports.max_observability_zls_events;

pub const artifact_scan_limit: usize = 500;

pub const ObservabilityError = ports.PortError || error{
    InvalidArtifactRegistryEntry,
};

pub const ProbeSnapshot = struct {
    ok: bool,
    status: []const u8,
    resolution: []const u8,
};

pub const BackendProbeCacheSnapshot = struct {
    zig: ?ProbeSnapshot = null,
    zls: ?ProbeSnapshot = null,
    zwanzig: ?ProbeSnapshot = null,
    zflame: ?ProbeSnapshot = null,
    diff_folded: ?ProbeSnapshot = null,
};

pub const AnalysisCacheSnapshot = struct {
    present: bool = false,
    hits: usize = 0,
    refreshes: usize = 0,
    bytes: usize = 0,
};

pub const ArtifactMetrics = struct {
    registry_available: bool = false,
    registry_entries: usize = 0,
    scanned_artifacts: usize = 0,
    scan_limit: usize = 0,
    status: []const u8 = "not_scanned",
};

pub const BaseMetrics = struct {
    workspace: []const u8,
    command_calls: usize,
    zls_requests: usize,
    tool_errors: usize,
    zls_status: []const u8,
    zls_last_failure: ?[]const u8,
    zls_restart_attempts: usize,
    backend_probe_cache: BackendProbeCacheSnapshot,
    analysis_cache: AnalysisCacheSnapshot,
    artifacts: ArtifactMetrics,
};

pub const MetricsReport = struct {
    base: BaseMetrics,
    observed: ports.ObservabilitySnapshot,
};

pub fn metricsReport(allocator: std.mem.Allocator, context: app_context.ObservabilityContext) ObservabilityError!MetricsReport {
    const observed = try context.observability_reader.snapshot(allocator);
    errdefer observed.deinit(allocator);
    return .{
        .base = baseMetrics(allocator, context),
        .observed = observed,
    };
}

pub fn baseMetrics(allocator: std.mem.Allocator, context: app_context.ObservabilityContext) BaseMetrics {
    return .{
        .workspace = context.workspace.root,
        .command_calls = if (context.counters.command_calls) |counter| counter.* else 0,
        .zls_requests = if (context.counters.zls_requests) |counter| counter.* else 0,
        .tool_errors = if (context.counters.tool_errors) |counter| counter.* else 0,
        .zls_status = context.zls_state.status,
        .zls_last_failure = context.zls_state.last_failure,
        .zls_restart_attempts = context.zls_state.restart_attempts,
        .backend_probe_cache = probeCache(context.probe_cache),
        .analysis_cache = .{
            .present = context.caches.analysis.cached,
            .hits = context.caches.analysis.hits,
            .refreshes = context.caches.analysis.refreshes,
            .bytes = context.caches.analysis.bytes,
        },
        .artifacts = artifactMetrics(allocator, context),
    };
}

fn artifactMetrics(allocator: std.mem.Allocator, context: app_context.ObservabilityContext) ArtifactMetrics {
    var out: ArtifactMetrics = .{ .scan_limit = artifact_scan_limit };
    const artifact_context: app_context.ArtifactContext = .{
        .workspace = context.workspace,
        .workspace_store = context.workspace_store,
    };
    const registry = artifact_registry.readRegistrySnapshot(allocator, artifact_context) catch |err| {
        out.status = @errorName(err);
        return out;
    };
    out.registry_available = registry.entries.len > 0;
    out.registry_entries = registry.entries.len;

    const scan = artifact_registry.scanArtifacts(allocator, artifact_context, null, artifact_scan_limit, false) catch |err| {
        out.status = @errorName(err);
        return out;
    };
    out.scanned_artifacts = scan.artifacts.len;
    out.status = if (scan.limit_reached) "scan_limit_reached" else "ok";
    return out;
}

fn probeCache(cache: app_context.TrustProbeCache) BackendProbeCacheSnapshot {
    return .{
        .zig = probeSnapshot(cache.zig),
        .zls = probeSnapshot(cache.zls),
        .zwanzig = probeSnapshot(cache.zwanzig),
        .zflame = probeSnapshot(cache.zflame),
        .diff_folded = probeSnapshot(cache.diff_folded),
    };
}

fn probeSnapshot(probe: app_context.CachedBackendProbe) ?ProbeSnapshot {
    if (!probe.probed) return null;
    return .{
        .ok = probe.ok orelse false,
        .status = probe.status,
        .resolution = probe.resolution,
    };
}

test "metrics report combines counters, cache state, artifacts, and observed rings" {
    const Stub = struct {
        var tool_stats = [_]ports.ObservabilityToolStats{
            .{ .name = "zig_build", .calls = 2, .errors = 1, .total_latency_ms = 14, .max_latency_ms = 10, .last_latency_ms = 10, .last_error = true },
        };
        var commands = [_]ports.ObservabilityCommandEvent{
            .{ .sequence = 1, .title = "zig build", .argv0 = "zig", .duration_ms = 11, .ok = true },
        };

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
        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return error.AccessDenied;
        }

        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

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

        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return error.FileNotFound;
        }

        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        fn workspaceResolve(_: *anyopaque, _: std.mem.Allocator, request: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
            return .{ .path = request.path };
        }

        fn scanDirectory(_: *anyopaque, _: std.mem.Allocator, request: ports.WorkspaceDirectoryScanRequest) ports.PortError!ports.WorkspaceDirectoryScanResult {
            if (request.max_files != artifact_scan_limit) return error.UnexpectedCall;
            return .{ .entries = entries[0..] };
        }

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
