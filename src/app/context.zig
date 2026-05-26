const std = @import("std");

const ports = @import("ports.zig");

pub const ContextError = error{
    MissingPort,
};

pub const WorkspaceView = struct {
    root: []const u8 = "",
    cache_root: []const u8 = "",
    transport: []const u8 = "unknown",
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,

    pub fn configured(self: WorkspaceView) bool {
        return self.root.len > 0;
    }
};

pub const ToolPaths = struct {
    zig: []const u8 = "zig",
    zls: []const u8 = "zls",
    zlint: []const u8 = "zlint",
    zwanzig: []const u8 = "zwanzig",
    zflame: []const u8 = "zflame",
    diff_folded: []const u8 = "diff-folded",
};

pub const Timeouts = struct {
    command_ms: i64 = 30_000,
    zls_ms: i64 = 30_000,
};

pub const PlatformView = struct {
    os: []const u8 = "unknown",
    arch: []const u8 = "unknown",
    is_windows: bool = false,
    is_linux: bool = false,
};

pub const ZlsState = struct {
    status: []const u8 = "not started",
    initialize_response: ?[]const u8 = null,
    last_failure: ?[]const u8 = null,
    restart_attempts: usize = 0,
    running: bool = false,

    pub fn connected(self: ZlsState) bool {
        return std.mem.eql(u8, self.status, "connected");
    }
};

pub const CounterHandles = struct {
    command_calls: ?*usize = null,
    zls_requests: ?*usize = null,
    tool_errors: ?*usize = null,

    pub fn incrementCommandCalls(self: CounterHandles) void {
        if (self.command_calls) |counter| counter.* += 1;
    }

    pub fn incrementZlsRequests(self: CounterHandles) void {
        if (self.zls_requests) |counter| counter.* += 1;
    }

    pub fn incrementToolErrors(self: CounterHandles) void {
        if (self.tool_errors) |counter| counter.* += 1;
    }
};

pub const CacheSnapshot = struct {
    cached: bool = false,
    signature: u64 = 0,
    hits: usize = 0,
    refreshes: usize = 0,
    bytes: usize = 0,
};

pub const BackendProbeCacheSnapshot = struct {
    zig: bool = false,
    zls: bool = false,
    zlint: bool = false,
    zwanzig: bool = false,
    zflame: bool = false,
    diff_folded: bool = false,

    pub fn anyCached(self: BackendProbeCacheSnapshot) bool {
        return self.zig or
            self.zls or
            self.zlint or
            self.zwanzig or
            self.zflame or
            self.diff_folded;
    }
};

pub const CachedBackendProbe = struct {
    probed: bool = false,
    ok: ?bool = null,
    status: []const u8 = "not probed",
    resolution: []const u8 = "call zigar_doctor with probe_backends=true to cache backend availability",
};

pub const ProfilingProbeCache = struct {
    zflame: CachedBackendProbe = .{},
    diff_folded: CachedBackendProbe = .{},
};

pub const CacheState = struct {
    backend_probe: BackendProbeCacheSnapshot = .{},
    analysis: CacheSnapshot = .{},
    semantic_index: CacheSnapshot = .{},
};

pub const PortSet = struct {
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

pub const TrustProbeCache = struct {
    zig: CachedBackendProbe = .{},
    zls: CachedBackendProbe = .{},
    zlint: CachedBackendProbe = .{},
    zwanzig: CachedBackendProbe = .{},
    zflame: CachedBackendProbe = .{},
    diff_folded: CachedBackendProbe = .{},
};

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

pub const CoreCommandContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    zls_state: ZlsState,
    command_runner: ports.CommandRunner,
    workspace_store: ports.WorkspaceStore,
    observability: ?ports.ObservabilitySink = null,
};

pub const ValidationContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    command_runner: ports.CommandRunner,
    workspace_store: ports.WorkspaceStore,
    clock_and_ids: ports.ClockAndIds,
    observability: ?ports.ObservabilitySink = null,
};

pub const EditingContext = struct {
    workspace: WorkspaceView,
    workspace_store: ports.WorkspaceStore,
    clock_and_ids: ports.ClockAndIds,
    observability: ?ports.ObservabilitySink = null,
};

pub const ArtifactContext = struct {
    workspace: WorkspaceView,
    workspace_store: ports.WorkspaceStore,
    observability: ?ports.ObservabilitySink = null,
};

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

pub const ReleaseDocsContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    workspace_store: ports.WorkspaceStore,
    toolchain_env: ports.ToolchainEnv,
    docs_scanner: ports.DocsScanner,
    observability: ?ports.ObservabilitySink = null,
};

pub const ZlsContext = struct {
    workspace: WorkspaceView,
    tool_paths: ToolPaths,
    timeouts: Timeouts,
    zls_state: ZlsState,
    zls_gateway: ports.ZlsGateway,
    observability: ?ports.ObservabilitySink = null,
};

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

pub const ObservabilityContext = struct {
    workspace: WorkspaceView,
    zls_state: ZlsState,
    counters: CounterHandles = .{},
    caches: CacheState = .{},
    probe_cache: TrustProbeCache = .{},
    workspace_store: ports.WorkspaceStore,
    observability_reader: ports.ObservabilityReader,
};

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

    pub fn requireCommandRunner(self: Context) ContextError!ports.CommandRunner {
        return self.ports.command_runner orelse ContextError.MissingPort;
    }

    pub fn requireWorkspace(self: Context) ContextError!ports.WorkspaceStore {
        return self.ports.workspace orelse ContextError.MissingPort;
    }

    pub fn requireRuntimeSession(self: Context) ContextError!ports.RuntimeSession {
        return self.ports.runtime_session orelse ContextError.MissingPort;
    }

    pub fn requireToolCatalog(self: Context) ContextError!ports.ToolCatalog {
        return self.ports.tool_catalog orelse ContextError.MissingPort;
    }

    pub fn requireToolManifest(self: Context) ContextError!ports.ToolManifestCatalog {
        return self.ports.tool_manifest orelse ContextError.MissingPort;
    }

    pub fn requireWorkspaceScanner(self: Context) ContextError!ports.WorkspaceScanner {
        return self.ports.workspace_scanner orelse ContextError.MissingPort;
    }

    pub fn requireObservabilityReader(self: Context) ContextError!ports.ObservabilityReader {
        return self.ports.observability_reader orelse ContextError.MissingPort;
    }

    pub fn requireSemanticIndexCache(self: Context) ContextError!ports.StaticCache {
        return self.ports.semantic_index_cache orelse ContextError.MissingPort;
    }

    pub fn requireToolchainEnv(self: Context) ContextError!ports.ToolchainEnv {
        return self.ports.toolchain_env orelse ContextError.MissingPort;
    }

    pub fn requireDocsScanner(self: Context) ContextError!ports.DocsScanner {
        return self.ports.docs_scanner orelse ContextError.MissingPort;
    }

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

    pub fn editing(self: Context) ContextError!EditingContext {
        return .{
            .workspace = self.workspace,
            .workspace_store = try self.requireWorkspace(),
            .clock_and_ids = self.ports.clock_and_ids orelse return ContextError.MissingPort,
            .observability = self.ports.observability,
        };
    }

    pub fn artifacts(self: Context) ContextError!ArtifactContext {
        return .{
            .workspace = self.workspace,
            .workspace_store = try self.requireWorkspace(),
            .observability = self.ports.observability,
        };
    }

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
