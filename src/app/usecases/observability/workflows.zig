//! Observability aggregation usecases. Reads process-local counters, runtime
//! snapshots, and artifact summaries without mutating workspace state.
const std = @import("std");

const app_context = @import("../../context.zig");
const artifact_registry = @import("../artifacts/registry.zig");
const ports = @import("../../ports.zig");

/// Maximum tool stats accepted by this workflow module.
pub const max_tool_stats = ports.max_observability_tool_stats;
/// Maximum MCP method stats accepted by this workflow module.
pub const max_method_stats = ports.max_observability_method_stats;
/// Maximum latency samples retained per observed key.
pub const max_latency_samples = ports.max_observability_latency_samples;
/// Minimum retained samples before percentile fields are published.
pub const min_percentile_samples = ports.min_observability_percentile_samples;
/// Maximum recent tool-call correlations accepted by this workflow module.
pub const max_tool_call_correlations = ports.max_observability_tool_call_correlations;
/// Maximum command events accepted by this workflow module.
pub const max_command_events = ports.max_observability_command_events;
/// Maximum backend events accepted by this workflow module.
pub const max_backend_events = ports.max_observability_backend_events;
/// Maximum zls events accepted by this workflow module.
pub const max_zls_events = ports.max_observability_zls_events;
/// Maximum startup phase timings accepted by this workflow module.
pub const max_startup_phases = ports.max_observability_startup_phases;
/// Maximum cancellation events accepted by this workflow module.
pub const max_cancellation_events = ports.max_observability_cancellation_events;

/// Artifact scan limit applied when collecting workflow evidence.
pub const artifact_scan_limit: usize = 500;

/// Error set returned by observability workflow failures.
pub const ObservabilityError = ports.PortError || error{
    InvalidArtifactRegistryEntry,
};

/// Carries probe snapshot data across use case and port boundaries.
/// Strings borrow from the originating `CachedBackendProbe`; the snapshot is
/// only valid while the source context is alive.
pub const ProbeSnapshot = struct {
    ok: bool,
    status: []const u8,
    resolution: []const u8,
};

/// Carries backend probe cache snapshot data across use case and port boundaries.
/// A null field means that backend was never probed this session, which is
/// distinct from a probed-but-failed entry (`ok = false`).
pub const BackendProbeCacheSnapshot = struct {
    zig: ?ProbeSnapshot = null,
    zls: ?ProbeSnapshot = null,
    zwanzig: ?ProbeSnapshot = null,
    zflame: ?ProbeSnapshot = null,
    diff_folded: ?ProbeSnapshot = null,
};

/// Carries analysis cache snapshot data across use case and port boundaries.
pub const AnalysisCacheSnapshot = struct {
    present: bool = false,
    hits: usize = 0,
    refreshes: usize = 0,
    bytes: usize = 0,
};

/// Carries artifact metrics data across use case and port boundaries.
pub const ArtifactMetrics = struct {
    registry_available: bool = false,
    registry_entries: usize = 0,
    scanned_artifacts: usize = 0,
    scan_limit: usize = 0,
    status: []const u8 = "not_scanned",
};

/// Carries base metrics data across use case and port boundaries.
/// String fields (`workspace`, `zls_status`, `zls_last_failure`) borrow from
/// the originating context and are not duplicated; the struct is only safe to
/// use while the context outlives it.
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

/// Carries metrics report data across use case and port boundaries.
pub const MetricsReport = struct {
    base: BaseMetrics,
    observed: ports.ObservabilitySnapshot,
};

/// Combines the live observability ring snapshot with the derived base metrics.
/// The returned `observed` snapshot is owned by `allocator`; the caller must
/// call its `deinit` (this function frees it only on a later failure path).
pub fn metricsReport(allocator: std.mem.Allocator, context: app_context.ObservabilityContext) ObservabilityError!MetricsReport {
    const observed = try context.observability_reader.snapshot(allocator);
    errdefer observed.deinit(allocator);
    return .{
        .base = baseMetrics(allocator, context),
        .observed = observed,
    };
}

/// Snapshots process-local counters, ZLS state, cache stats, and artifact
/// metrics into a single value. String fields borrow from `context` (not
/// duplicated); the artifact summary allocates scratch through `allocator`.
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

/// Summarizes the artifact registry and a bounded workspace scan. Failures are
/// non-fatal: a registry or scan error is recorded in `status` (via @errorName)
/// so the metrics report still renders. Scans are read-only and never hashed.
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

/// Converts the full per-backend trust probe cache into the report snapshot
/// shape, mapping unprobed entries to null so callers can distinguish them
/// from probed-and-failed entries.
fn probeCache(cache: app_context.TrustProbeCache) BackendProbeCacheSnapshot {
    return .{
        .zig = probeSnapshot(cache.zig),
        .zls = probeSnapshot(cache.zls),
        .zwanzig = probeSnapshot(cache.zwanzig),
        .zflame = probeSnapshot(cache.zflame),
        .diff_folded = probeSnapshot(cache.diff_folded),
    };
}

/// Converts a cached backend probe to a snapshot, or null when never probed so
/// the report can distinguish "unprobed" from "probed and failed".
fn probeSnapshot(probe: app_context.CachedBackendProbe) ?ProbeSnapshot {
    if (!probe.probed) return null;
    return .{
        .ok = probe.ok orelse false,
        .status = probe.status,
        .resolution = probe.resolution,
    };
}
