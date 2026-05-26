//! Dependency-injected app contexts used by usecases. Slices are borrowed from
//! host configuration, while optional ports gate side effects by capability.
const std = @import("std");

const ports = @import("ports.zig");

/// Returned when a narrowed context requires a port that was not bound.
pub const ContextError = error{
    MissingPort,
};

/// Borrowed workspace and transport metadata projected from bootstrap config.
pub const WorkspaceView = struct {
    root: []const u8 = "",
    cache_root: []const u8 = "",
    transport: []const u8 = "unknown",
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,

    /// True when a concrete workspace root was projected into the context.
    pub fn configured(self: WorkspaceView) bool {
        return self.root.len > 0;
    }
};

/// Borrowed command paths used by app use cases when constructing backend argv.
pub const ToolPaths = struct {
    zig: []const u8 = "zig",
    zls: []const u8 = "zls",
    zlint: []const u8 = "zlint",
    zwanzig: []const u8 = "zwanzig",
    zflame: []const u8 = "zflame",
    diff_folded: []const u8 = "diff-folded",
};

/// Default command and ZLS timeout policy in milliseconds.
pub const Timeouts = struct {
    command_ms: i64 = 30_000,
    zls_ms: i64 = 30_000,
};

/// Borrowed platform facts projected by bootstrap for app-level branching.
pub const PlatformView = struct {
    os: []const u8 = "unknown",
    arch: []const u8 = "unknown",
    is_windows: bool = false,
    is_linux: bool = false,
};

/// Read-only snapshot of the current ZLS lifecycle state.
pub const ZlsState = struct {
    status: []const u8 = "not started",
    initialize_response: ?[]const u8 = null,
    last_failure: ?[]const u8 = null,
    restart_attempts: usize = 0,
    running: bool = false,

    /// True only for the connected status emitted by the ZLS session layer.
    pub fn connected(self: ZlsState) bool {
        return std.mem.eql(u8, self.status, "connected");
    }
};

/// Optional mutable counters owned by bootstrap and incremented by app workflows.
pub const CounterHandles = struct {
    command_calls: ?*usize = null,
    zls_requests: ?*usize = null,
    tool_errors: ?*usize = null,

    /// Increments command_calls when the counter handle is present.
    pub fn incrementCommandCalls(self: CounterHandles) void {
        if (self.command_calls) |counter| counter.* += 1;
    }

    /// Increments zls_requests when the counter handle is present.
    pub fn incrementZlsRequests(self: CounterHandles) void {
        if (self.zls_requests) |counter| counter.* += 1;
    }

    /// Increments tool_errors when the counter handle is present.
    pub fn incrementToolErrors(self: CounterHandles) void {
        if (self.tool_errors) |counter| counter.* += 1;
    }
};

/// Read-only static cache metrics exposed without transferring cache ownership.
pub const CacheSnapshot = struct {
    cached: bool = false,
    signature: u64 = 0,
    hits: usize = 0,
    refreshes: usize = 0,
    bytes: usize = 0,
};

/// Boolean backend probe cache presence by tool.
pub const BackendProbeCacheSnapshot = struct {
    zig: bool = false,
    zls: bool = false,
    zlint: bool = false,
    zwanzig: bool = false,
    zflame: bool = false,
    diff_folded: bool = false,

    /// True when at least one backend probe result is cached.
    pub fn anyCached(self: BackendProbeCacheSnapshot) bool {
        return self.zig or
            self.zls or
            self.zlint or
            self.zwanzig or
            self.zflame or
            self.diff_folded;
    }
};

/// Backend probe result snapshot that avoids exposing mutable runtime cache entries.
pub const CachedBackendProbe = struct {
    probed: bool = false,
    ok: ?bool = null,
    status: []const u8 = "not probed",
    resolution: []const u8 = "call zigar_doctor with probe_backends=true to cache backend availability",
};

/// Profiling-specific cached probe snapshots.
pub const ProfilingProbeCache = struct {
    zflame: CachedBackendProbe = .{},
    diff_folded: CachedBackendProbe = .{},
};

/// Aggregated runtime cache snapshots exposed to runtime UX and observability.
pub const CacheState = struct {
    backend_probe: BackendProbeCacheSnapshot = .{},
    analysis: CacheSnapshot = .{},
    semantic_index: CacheSnapshot = .{},
};

/// Optional capability table assembled by bootstrap for app use cases.
pub const PortSet = struct {
    /// Optional capabilities assembled by the runtime; missing entries must be
    /// treated as unavailable effects by callers.
    command_runner: ?ports.CommandRunner = null,
    workspace: ?ports.WorkspaceStore = null,
    workspace_scanner: ?ports.WorkspaceScanner = null,
    analysis_cache: ?ports.StaticCache = null,
    semantic_index_cache: ?ports.StaticCache = null,
    toolchain_env: ?ports.ToolchainEnv = null,
    docs_scanner: ?ports.DocsScanner = null,
    zls_gateway: ?ports.ZlsGateway = null,
    backend_probe: ?ports.BackendProbe = null,
    artifact_store: ?ports.ArtifactStore = null,
    runtime_session: ?ports.RuntimeSession = null,
    tool_catalog: ?ports.ToolCatalog = null,
    tool_manifest: ?ports.ToolManifestCatalog = null,
    observability: ?ports.ObservabilitySink = null,
    observability_reader: ?ports.ObservabilityReader = null,
    clock_and_ids: ?ports.ClockAndIds = null,

    /// True when any side-effecting or state-reading capability is present.
    pub fn hasEffects(self: PortSet) bool {
        return self.command_runner != null or
            self.workspace != null or
            self.workspace_scanner != null or
            self.analysis_cache != null or
            self.semantic_index_cache != null or
            self.toolchain_env != null or
            self.docs_scanner != null or
            self.zls_gateway != null or
            self.backend_probe != null or
            self.artifact_store != null or
            self.runtime_session != null or
            self.tool_catalog != null or
            self.tool_manifest != null or
            self.observability != null or
            self.observability_reader != null or
            self.clock_and_ids != null;
    }
};

/// Dependencies required by profiling command use cases.
pub const ProfilingContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    command_runner: ports.CommandRunner,
    workspace_store: ports.WorkspaceStore,
    backend_probe: ?ports.BackendProbe = null,
    probe_cache: ProfilingProbeCache = .{},
    artifact_store: ?ports.ArtifactStore = null,
    observability: ?ports.ObservabilitySink = null,
    clock_and_ids: ?ports.ClockAndIds = null,
};

/// Dependencies required by benchmark and coverage use cases.
pub const PerformanceContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    platform: PlatformView = .{},
    command_runner: ports.CommandRunner,
    workspace_store: ports.WorkspaceStore,
    workspace_scanner: ports.WorkspaceScanner,
    backend_probe: ?ports.BackendProbe = null,
    artifact_store: ?ports.ArtifactStore = null,
    observability: ?ports.ObservabilitySink = null,
    clock_and_ids: ?ports.ClockAndIds = null,
};

/// Dependencies required by crash, debugger, and binary diagnostic use cases.
pub const DiagnosticsContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    platform: PlatformView = .{},
    command_runner: ports.CommandRunner,
    workspace_store: ports.WorkspaceStore,
    workspace_scanner: ports.WorkspaceScanner,
    backend_probe: ?ports.BackendProbe = null,
    artifact_store: ?ports.ArtifactStore = null,
    observability: ?ports.ObservabilitySink = null,
    clock_and_ids: ?ports.ClockAndIds = null,
};

/// Dependencies required by release workflow use cases.
pub const ReleaseWorkflowContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    command_runner: ports.CommandRunner,
    workspace_store: ports.WorkspaceStore,
    workspace_scanner: ports.WorkspaceScanner,
    tool_manifest: ports.ToolManifestCatalog,
    artifact_store: ?ports.ArtifactStore = null,
    observability: ?ports.ObservabilitySink = null,
    clock_and_ids: ?ports.ClockAndIds = null,

    /// Reuses release workflow dependencies for static analysis helpers.
    pub fn staticAnalysis(self: ReleaseWorkflowContext) StaticAnalysisContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .command_runner = self.command_runner,
            .workspace_store = self.workspace_store,
            .workspace_scanner = self.workspace_scanner,
            .observability = self.observability,
        };
    }
};

/// Dependencies required by environment doctor and backend discovery use cases.
pub const EnvironmentContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    platform: PlatformView = .{},
    command_runner: ports.CommandRunner,
    workspace_store: ports.WorkspaceStore,
    workspace_scanner: ports.WorkspaceScanner,
    backend_probe: ?ports.BackendProbe = null,
    artifact_store: ?ports.ArtifactStore = null,
    observability: ?ports.ObservabilitySink = null,
    clock_and_ids: ?ports.ClockAndIds = null,

    /// Reuses environment dependencies for static analysis helpers.
    pub fn staticAnalysis(self: EnvironmentContext) StaticAnalysisContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .command_runner = self.command_runner,
            .workspace_store = self.workspace_store,
            .workspace_scanner = self.workspace_scanner,
            .observability = self.observability,
        };
    }
};

/// Dependencies required by adoption guidance use cases.
pub const AdoptionContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    platform: PlatformView = .{},
    command_runner: ports.CommandRunner,
    workspace_store: ports.WorkspaceStore,
    workspace_scanner: ports.WorkspaceScanner,
    backend_probe: ?ports.BackendProbe = null,
    artifact_store: ?ports.ArtifactStore = null,
    observability: ?ports.ObservabilitySink = null,
    clock_and_ids: ?ports.ClockAndIds = null,

    /// Reuses adoption dependencies for static analysis helpers.
    pub fn staticAnalysis(self: AdoptionContext) StaticAnalysisContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .command_runner = self.command_runner,
            .workspace_store = self.workspace_store,
            .workspace_scanner = self.workspace_scanner,
            .observability = self.observability,
        };
    }
};

/// Trust workflow view of cached backend probe outcomes.
pub const TrustProbeCache = struct {
    zig: CachedBackendProbe = .{},
    zls: CachedBackendProbe = .{},
    zlint: CachedBackendProbe = .{},
    zwanzig: CachedBackendProbe = .{},
    zflame: CachedBackendProbe = .{},
    diff_folded: CachedBackendProbe = .{},
};

/// Dependencies required by trust and policy use cases.
pub const TrustContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    command_runner: ports.CommandRunner,
    workspace_store: ports.WorkspaceStore,
    tool_manifest: ports.ToolManifestCatalog,
    probe_cache: TrustProbeCache = .{},
    observability: ?ports.ObservabilitySink = null,
    clock_and_ids: ?ports.ClockAndIds = null,
};

/// Dependencies required by direct Zig command wrappers.
pub const CoreCommandContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    zls_state: ZlsState,
    command_runner: ports.CommandRunner,
    workspace_store: ports.WorkspaceStore,
    observability: ?ports.ObservabilitySink = null,
};

/// Dependencies required by validation plan, run, and history use cases.
pub const ValidationContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    command_runner: ports.CommandRunner,
    workspace_store: ports.WorkspaceStore,
    clock_and_ids: ports.ClockAndIds,
    observability: ?ports.ObservabilitySink = null,
};

/// Dependencies required by editing and patch-session use cases.
pub const EditingContext = struct {
    workspace: WorkspaceView,
    workspace_store: ports.WorkspaceStore,
    clock_and_ids: ports.ClockAndIds,
    observability: ?ports.ObservabilitySink = null,
};

/// Dependencies required by artifact registry use cases.
pub const ArtifactContext = struct {
    workspace: WorkspaceView,
    workspace_store: ports.WorkspaceStore,
    observability: ?ports.ObservabilitySink = null,
};

/// Dependencies required by static analysis scans and semantic indexing.
pub const StaticAnalysisContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths = .{},
    timeouts: Timeouts = .{},
    command_runner: ?ports.CommandRunner = null,
    workspace_store: ports.WorkspaceStore,
    workspace_scanner: ports.WorkspaceScanner,
    analysis_cache: ?ports.StaticCache = null,
    semantic_index_cache: ?ports.StaticCache = null,
    observability: ?ports.ObservabilitySink = null,
};

/// Dependencies required by release documentation index use cases.
pub const ReleaseDocsContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    workspace_store: ports.WorkspaceStore,
    toolchain_env: ports.ToolchainEnv,
    docs_scanner: ports.DocsScanner,
    observability: ?ports.ObservabilitySink = null,
};

/// Dependencies required by ZLS code intelligence use cases.
pub const ZlsContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    zls_state: ZlsState,
    zls_gateway: ports.ZlsGateway,
    observability: ?ports.ObservabilitySink = null,
};

/// Dependencies required by runtime UX session, catalog, and job views.
pub const RuntimeUxContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    zls_state: ZlsState,
    counters: CounterHandles = .{},
    caches: CacheState = .{},
    command_runner: ports.CommandRunner,
    workspace_store: ports.WorkspaceStore,
    workspace_scanner: ports.WorkspaceScanner,
    runtime_session: ports.RuntimeSession,
    tool_catalog: ?ports.ToolCatalog = null,
    tool_manifest: ?ports.ToolManifestCatalog = null,
    observability: ?ports.ObservabilitySink = null,
};

/// Dependencies required by observability snapshot use cases.
pub const ObservabilityContext = struct {
    workspace: WorkspaceView,
    zls_state: ZlsState,
    counters: CounterHandles = .{},
    caches: CacheState = .{},
    probe_cache: TrustProbeCache = .{},
    workspace_store: ports.WorkspaceStore,
    observability_reader: ports.ObservabilityReader,
};

/// Dependencies required by project intelligence and agent context use cases.
pub const ProjectIntelligenceContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    zls_state: ZlsState,
    command_runner: ports.CommandRunner,
    workspace_store: ports.WorkspaceStore,
    workspace_scanner: ports.WorkspaceScanner,
    analysis_cache: ?ports.StaticCache = null,
    semantic_index_cache: ?ports.StaticCache = null,
    clock_and_ids: ports.ClockAndIds,
    observability: ?ports.ObservabilitySink = null,

    /// Reuses project intelligence dependencies for static analysis helpers.
    pub fn staticAnalysis(self: ProjectIntelligenceContext) StaticAnalysisContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .command_runner = self.command_runner,
            .workspace_store = self.workspace_store,
            .workspace_scanner = self.workspace_scanner,
            .analysis_cache = self.analysis_cache,
            .semantic_index_cache = self.semantic_index_cache,
            .observability = self.observability,
        };
    }

    /// Reuses project intelligence dependencies for validation helpers.
    pub fn validation(self: ProjectIntelligenceContext) ValidationContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .command_runner = self.command_runner,
            .workspace_store = self.workspace_store,
            .clock_and_ids = self.clock_and_ids,
            .observability = self.observability,
        };
    }
};

/// Top-level app context with borrowed config snapshots and optional capability ports.
pub const Context = struct {
    workspace: WorkspaceView = .{},
    tool_paths: ToolPaths = .{},
    timeouts: Timeouts = .{},
    platform: PlatformView = .{},
    zls_state: ZlsState = .{},
    ports: PortSet = .{},
    counters: CounterHandles = .{},
    caches: CacheState = .{},
    profiling_probe_cache: ProfilingProbeCache = .{},
    trust_probe_cache: TrustProbeCache = .{},

    /// Returns the command runner port or MissingPort when command execution is unavailable.
    pub fn requireCommandRunner(self: Context) ContextError!ports.CommandRunner {
        return self.ports.command_runner orelse ContextError.MissingPort;
    }

    /// Returns the workspace store port or MissingPort when workspace IO is unavailable.
    pub fn requireWorkspace(self: Context) ContextError!ports.WorkspaceStore {
        return self.ports.workspace orelse ContextError.MissingPort;
    }

    /// Returns the runtime session port or MissingPort when runtime UX state is unavailable.
    pub fn requireRuntimeSession(self: Context) ContextError!ports.RuntimeSession {
        return self.ports.runtime_session orelse ContextError.MissingPort;
    }

    /// Returns the tool catalog port or MissingPort when catalog reads are unavailable.
    pub fn requireToolCatalog(self: Context) ContextError!ports.ToolCatalog {
        return self.ports.tool_catalog orelse ContextError.MissingPort;
    }

    /// Returns the tool manifest port or MissingPort when manifest metadata is unavailable.
    pub fn requireToolManifest(self: Context) ContextError!ports.ToolManifestCatalog {
        return self.ports.tool_manifest orelse ContextError.MissingPort;
    }

    /// Returns the workspace scanner port or MissingPort when scans are unavailable.
    pub fn requireWorkspaceScanner(self: Context) ContextError!ports.WorkspaceScanner {
        return self.ports.workspace_scanner orelse ContextError.MissingPort;
    }

    /// Returns the observability reader port or MissingPort when metrics state is unavailable.
    pub fn requireObservabilityReader(self: Context) ContextError!ports.ObservabilityReader {
        return self.ports.observability_reader orelse ContextError.MissingPort;
    }

    /// Returns the semantic index cache port or MissingPort when cache access is unavailable.
    pub fn requireSemanticIndexCache(self: Context) ContextError!ports.StaticCache {
        return self.ports.semantic_index_cache orelse ContextError.MissingPort;
    }

    /// Returns the toolchain environment port or MissingPort when env inspection is unavailable.
    pub fn requireToolchainEnv(self: Context) ContextError!ports.ToolchainEnv {
        return self.ports.toolchain_env orelse ContextError.MissingPort;
    }

    /// Returns the documentation scanner port or MissingPort when docs scans are unavailable.
    pub fn requireDocsScanner(self: Context) ContextError!ports.DocsScanner {
        return self.ports.docs_scanner orelse ContextError.MissingPort;
    }

    /// Narrows the top-level context to profiling dependencies.
    pub fn profiling(self: Context) ContextError!ProfilingContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .command_runner = try self.requireCommandRunner(),
            .workspace_store = try self.requireWorkspace(),
            .backend_probe = self.ports.backend_probe,
            .probe_cache = self.profiling_probe_cache,
            .artifact_store = self.ports.artifact_store,
            .observability = self.ports.observability,
            .clock_and_ids = self.ports.clock_and_ids,
        };
    }

    /// Narrows the top-level context to performance dependencies.
    pub fn performance(self: Context) ContextError!PerformanceContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .platform = self.platform,
            .command_runner = try self.requireCommandRunner(),
            .workspace_store = try self.requireWorkspace(),
            .workspace_scanner = try self.requireWorkspaceScanner(),
            .backend_probe = self.ports.backend_probe,
            .artifact_store = self.ports.artifact_store,
            .observability = self.ports.observability,
            .clock_and_ids = self.ports.clock_and_ids,
        };
    }

    /// Narrows the top-level context to diagnostics dependencies.
    pub fn diagnostics(self: Context) ContextError!DiagnosticsContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .platform = self.platform,
            .command_runner = try self.requireCommandRunner(),
            .workspace_store = try self.requireWorkspace(),
            .workspace_scanner = try self.requireWorkspaceScanner(),
            .backend_probe = self.ports.backend_probe,
            .artifact_store = self.ports.artifact_store,
            .observability = self.ports.observability,
            .clock_and_ids = self.ports.clock_and_ids,
        };
    }

    /// Narrows the top-level context to release workflow dependencies.
    pub fn releaseWorkflows(self: Context) ContextError!ReleaseWorkflowContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .command_runner = try self.requireCommandRunner(),
            .workspace_store = try self.requireWorkspace(),
            .workspace_scanner = try self.requireWorkspaceScanner(),
            .tool_manifest = try self.requireToolManifest(),
            .artifact_store = self.ports.artifact_store,
            .observability = self.ports.observability,
            .clock_and_ids = self.ports.clock_and_ids,
        };
    }

    /// Narrows the top-level context to environment dependencies.
    pub fn environment(self: Context) ContextError!EnvironmentContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .platform = self.platform,
            .command_runner = try self.requireCommandRunner(),
            .workspace_store = try self.requireWorkspace(),
            .workspace_scanner = try self.requireWorkspaceScanner(),
            .backend_probe = self.ports.backend_probe,
            .artifact_store = self.ports.artifact_store,
            .observability = self.ports.observability,
            .clock_and_ids = self.ports.clock_and_ids,
        };
    }

    /// Narrows the top-level context to adoption dependencies.
    pub fn adoption(self: Context) ContextError!AdoptionContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .platform = self.platform,
            .command_runner = try self.requireCommandRunner(),
            .workspace_store = try self.requireWorkspace(),
            .workspace_scanner = try self.requireWorkspaceScanner(),
            .backend_probe = self.ports.backend_probe,
            .artifact_store = self.ports.artifact_store,
            .observability = self.ports.observability,
            .clock_and_ids = self.ports.clock_and_ids,
        };
    }

    /// Narrows the top-level context to trust dependencies.
    pub fn trust(self: Context) ContextError!TrustContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .command_runner = try self.requireCommandRunner(),
            .workspace_store = try self.requireWorkspace(),
            .tool_manifest = try self.requireToolManifest(),
            .probe_cache = self.trust_probe_cache,
            .observability = self.ports.observability,
            .clock_and_ids = self.ports.clock_and_ids,
        };
    }

    /// Narrows the top-level context to core command dependencies.
    pub fn coreCommands(self: Context) ContextError!CoreCommandContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .zls_state = self.zls_state,
            .command_runner = try self.requireCommandRunner(),
            .workspace_store = try self.requireWorkspace(),
            .observability = self.ports.observability,
        };
    }

    /// Narrows the top-level context to validation dependencies.
    pub fn validation(self: Context) ContextError!ValidationContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .command_runner = try self.requireCommandRunner(),
            .workspace_store = try self.requireWorkspace(),
            .clock_and_ids = self.ports.clock_and_ids orelse return ContextError.MissingPort,
            .observability = self.ports.observability,
        };
    }

    /// Narrows the top-level context to editing dependencies.
    pub fn editing(self: Context) ContextError!EditingContext {
        return .{
            .workspace = self.workspace,
            .workspace_store = try self.requireWorkspace(),
            .clock_and_ids = self.ports.clock_and_ids orelse return ContextError.MissingPort,
            .observability = self.ports.observability,
        };
    }

    /// Narrows the top-level context to artifact dependencies.
    pub fn artifacts(self: Context) ContextError!ArtifactContext {
        return .{
            .workspace = self.workspace,
            .workspace_store = try self.requireWorkspace(),
            .observability = self.ports.observability,
        };
    }

    /// Narrows the top-level context to static analysis dependencies.
    pub fn staticAnalysis(self: Context) ContextError!StaticAnalysisContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .command_runner = self.ports.command_runner,
            .workspace_store = try self.requireWorkspace(),
            .workspace_scanner = try self.requireWorkspaceScanner(),
            .analysis_cache = self.ports.analysis_cache,
            .semantic_index_cache = self.ports.semantic_index_cache,
            .observability = self.ports.observability,
        };
    }

    /// Narrows the top-level context to release documentation dependencies.
    pub fn releaseDocs(self: Context) ContextError!ReleaseDocsContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .workspace_store = try self.requireWorkspace(),
            .toolchain_env = try self.requireToolchainEnv(),
            .docs_scanner = try self.requireDocsScanner(),
            .observability = self.ports.observability,
        };
    }

    /// Narrows the top-level context to ZLS dependencies.
    pub fn zls(self: Context) ContextError!ZlsContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .zls_state = self.zls_state,
            .zls_gateway = self.ports.zls_gateway orelse return ContextError.MissingPort,
            .observability = self.ports.observability,
        };
    }

    /// Narrows the top-level context to runtime UX dependencies.
    pub fn runtimeUx(self: Context) ContextError!RuntimeUxContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .zls_state = self.zls_state,
            .counters = self.counters,
            .caches = self.caches,
            .command_runner = try self.requireCommandRunner(),
            .workspace_store = try self.requireWorkspace(),
            .workspace_scanner = try self.requireWorkspaceScanner(),
            .runtime_session = try self.requireRuntimeSession(),
            .tool_catalog = self.ports.tool_catalog,
            .tool_manifest = self.ports.tool_manifest,
            .observability = self.ports.observability,
        };
    }

    /// Narrows the top-level context to observability dependencies.
    pub fn observability(self: Context) ContextError!ObservabilityContext {
        return .{
            .workspace = self.workspace,
            .zls_state = self.zls_state,
            .counters = self.counters,
            .caches = self.caches,
            .probe_cache = self.trust_probe_cache,
            .workspace_store = try self.requireWorkspace(),
            .observability_reader = try self.requireObservabilityReader(),
        };
    }

    /// Narrows the top-level context to project intelligence dependencies.
    pub fn projectIntelligence(self: Context) ContextError!ProjectIntelligenceContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .zls_state = self.zls_state,
            .command_runner = try self.requireCommandRunner(),
            .workspace_store = try self.requireWorkspace(),
            .workspace_scanner = try self.requireWorkspaceScanner(),
            .analysis_cache = self.ports.analysis_cache,
            .semantic_index_cache = self.ports.semantic_index_cache,
            .clock_and_ids = self.ports.clock_and_ids orelse return ContextError.MissingPort,
            .observability = self.ports.observability,
        };
    }
};
