//! Observability aggregation usecases. Reads process-local counters, runtime
//! snapshots, and artifact summaries without mutating workspace state.
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
