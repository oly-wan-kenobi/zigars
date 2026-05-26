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

test "default context is transport free and has no effect ports" {
    const ctx = Context{};
    try std.testing.expect(!ctx.workspace.configured());
    try std.testing.expect(!ctx.ports.hasEffects());
    try std.testing.expectError(ContextError.MissingPort, ctx.requireCommandRunner());
}

test "profiling context requires only the pilot runtime capabilities" {
    const Stub = struct {
        fn commandRun(_: *anyopaque, _: std.mem.Allocator, _: ports.CommandRequest) ports.PortError!ports.CommandResult {
            return .{ .exit_code = 0, .stdout = "ok" };
        }

        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return .{ .bytes = "" };
        }

        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        const command_vtable = ports.CommandRunner.VTable{ .run = commandRun };
        const workspace_vtable = ports.WorkspaceStore.VTable{
            .read = workspaceRead,
            .write = workspaceWrite,
        };
    };

    var token: u8 = 0;
    const ctx = Context{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .tool_paths = .{ .zflame = "/bin/zflame", .diff_folded = "/bin/diff-folded" },
        .timeouts = .{ .command_ms = 5_000, .zls_ms = 7_000 },
        .ports = .{
            .command_runner = .{ .ptr = &token, .vtable = &Stub.command_vtable },
            .workspace = .{ .ptr = &token, .vtable = &Stub.workspace_vtable },
        },
    };

    const profiling_ctx = try ctx.profiling();
    try std.testing.expectEqualStrings("/workspace", profiling_ctx.workspace.root);
    try std.testing.expectEqualStrings("/bin/zflame", profiling_ctx.tool_paths.zflame);
    try std.testing.expectEqual(@as(i64, 5_000), profiling_ctx.timeouts.command_ms);
    try std.testing.expect(profiling_ctx.backend_probe == null);

    const command = try profiling_ctx.command_runner.run(std.testing.allocator, .{ .argv = &.{"zig"} });
    defer command.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", command.stdout);
    const read = try profiling_ctx.workspace_store.read(std.testing.allocator, .{ .path = "README.md" });
    defer read.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", read.bytes);
    const write = try profiling_ctx.workspace_store.write(.{ .path = "out.txt", .bytes = "bytes" });
    try std.testing.expectEqual(@as(usize, 5), write.bytes_written);
}

test "validation context requires command workspace and clock ports" {
    const Stub = struct {
        fn commandRun(_: *anyopaque, _: std.mem.Allocator, _: ports.CommandRequest) ports.PortError!ports.CommandResult {
            return .{ .exit_code = 0 };
        }

        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return .{ .bytes = "" };
        }

        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        fn now(_: *anyopaque) ports.PortError!ports.Instant {
            return .{ .unix_ms = 1_700_000_000_000, .monotonic_ms = 1 };
        }

        fn nextId(_: *anyopaque, allocator: std.mem.Allocator, request: ports.IdRequest) ports.PortError![]const u8 {
            return std.fmt.allocPrint(allocator, "{s}-1", .{request.prefix});
        }

        const command_vtable = ports.CommandRunner.VTable{ .run = commandRun };
        const workspace_vtable = ports.WorkspaceStore.VTable{
            .read = workspaceRead,
            .write = workspaceWrite,
        };
        const clock_vtable = ports.ClockAndIds.VTable{
            .now = now,
            .nextId = nextId,
        };
    };

    var token: u8 = 0;
    var missing_clock = Context{
        .ports = .{
            .command_runner = .{ .ptr = &token, .vtable = &Stub.command_vtable },
            .workspace = .{ .ptr = &token, .vtable = &Stub.workspace_vtable },
        },
    };
    try std.testing.expectError(ContextError.MissingPort, missing_clock.validation());

    missing_clock.ports.clock_and_ids = .{ .ptr = &token, .vtable = &Stub.clock_vtable };
    const validation_ctx = try missing_clock.validation();
    try std.testing.expectEqualStrings("zig", validation_ctx.tool_paths.zig);
    try std.testing.expectEqual(@as(i64, 30_000), validation_ctx.timeouts.command_ms);

    const command = try validation_ctx.command_runner.run(std.testing.allocator, .{ .argv = &.{"zig"} });
    defer command.deinit(std.testing.allocator);
    const read = try validation_ctx.workspace_store.read(std.testing.allocator, .{ .path = "build.zig" });
    defer read.deinit(std.testing.allocator);
    const write = try validation_ctx.workspace_store.write(.{ .path = "build.zig", .bytes = "pub fn main() void {}" });
    try std.testing.expectEqual(@as(usize, 21), write.bytes_written);
    const instant = try validation_ctx.clock_and_ids.now();
    try std.testing.expectEqual(@as(u64, 1), instant.monotonic_ms);
    const id = try validation_ctx.clock_and_ids.nextId(std.testing.allocator, .{ .prefix = "run" });
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("run-1", id);
}

test "editing context requires workspace and clock ports" {
    const Stub = struct {
        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return .{ .bytes = "" };
        }

        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        fn now(_: *anyopaque) ports.PortError!ports.Instant {
            return .{ .unix_ms = 1_700_000_000_000, .monotonic_ms = 1 };
        }

        fn nextId(_: *anyopaque, allocator: std.mem.Allocator, request: ports.IdRequest) ports.PortError![]const u8 {
            return std.fmt.allocPrint(allocator, "{s}1", .{request.prefix});
        }

        const workspace_vtable = ports.WorkspaceStore.VTable{
            .read = workspaceRead,
            .write = workspaceWrite,
        };
        const clock_vtable = ports.ClockAndIds.VTable{
            .now = now,
            .nextId = nextId,
        };
    };

    var token: u8 = 0;
    const ctx = Context{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .ports = .{
            .workspace = .{ .ptr = &token, .vtable = &Stub.workspace_vtable },
            .clock_and_ids = .{ .ptr = &token, .vtable = &Stub.clock_vtable },
        },
    };

    const editing_ctx = try ctx.editing();
    try std.testing.expectEqualStrings("/workspace", editing_ctx.workspace.root);
    const read = try editing_ctx.workspace_store.read(std.testing.allocator, .{ .path = "src/main.zig" });
    defer read.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", read.bytes);
    const write = try editing_ctx.workspace_store.write(.{ .path = "src/main.zig", .bytes = "const x = 1;" });
    try std.testing.expectEqual(@as(usize, 12), write.bytes_written);
    const instant = try editing_ctx.clock_and_ids.now();
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), instant.unix_ms);
    const id = try editing_ctx.clock_and_ids.nextId(std.testing.allocator, .{ .prefix = "edit-" });
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("edit-1", id);
}

test "counter handles are optional runtime bridges" {
    var command_calls: usize = 1;
    var zls_requests: usize = 2;
    var tool_errors: usize = 3;
    const counters = CounterHandles{
        .command_calls = &command_calls,
        .zls_requests = &zls_requests,
        .tool_errors = &tool_errors,
    };

    counters.incrementCommandCalls();
    counters.incrementZlsRequests();
    counters.incrementToolErrors();

    try std.testing.expectEqual(@as(usize, 2), command_calls);
    try std.testing.expectEqual(@as(usize, 3), zls_requests);
    try std.testing.expectEqual(@as(usize, 4), tool_errors);
}

test "cache snapshots expose status without concrete cache ownership" {
    const state = CacheState{
        .backend_probe = .{ .zig = true },
        .analysis = .{ .cached = true, .signature = 42, .hits = 3, .refreshes = 1 },
    };

    try std.testing.expect(state.backend_probe.anyCached());
    try std.testing.expect((BackendProbeCacheSnapshot{ .diff_folded = true }).anyCached());
    try std.testing.expect(state.analysis.cached);
    try std.testing.expectEqual(@as(u64, 42), state.analysis.signature);
}

test "static analysis context carries optional command and cache ports" {
    const Stub = struct {
        fn commandRun(_: *anyopaque, _: std.mem.Allocator, _: ports.CommandRequest) ports.PortError!ports.CommandResult {
            return .{ .exit_code = 0 };
        }

        fn workspaceRead(_: *anyopaque, _: std.mem.Allocator, _: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
            return .{ .bytes = "" };
        }

        fn workspaceWrite(_: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
            return .{ .bytes_written = request.bytes.len };
        }

        fn scanZigFiles(_: *anyopaque, allocator: std.mem.Allocator, _: ports.WorkspaceScanRequest) ports.PortError!ports.WorkspaceScanResult {
            return .{ .files = try allocator.alloc(ports.WorkspaceScanFile, 0), .owns_memory = true };
        }

        fn cacheStatus(_: *anyopaque) ports.PortError!ports.StaticCacheStatus {
            return .{ .cached = true, .signature = 99, .bytes_len = 2 };
        }

        fn cacheLoad(_: *anyopaque, _: std.mem.Allocator) ports.PortError!ports.StaticCacheLoadResult {
            return .{ .status = .{ .cached = true, .signature = 99, .bytes_len = 2 }, .bytes = "{}" };
        }

        fn cacheStore(_: *anyopaque, _: std.mem.Allocator, request: ports.StaticCacheStoreRequest) ports.PortError!ports.StaticCacheStatus {
            return .{ .cached = true, .signature = request.signature, .bytes_len = request.bytes.len, .refreshes = 1 };
        }

        fn cacheHit(_: *anyopaque) ports.PortError!ports.StaticCacheStatus {
            return .{ .cached = true, .signature = 99, .bytes_len = 2, .hits = 1 };
        }

        const command_vtable = ports.CommandRunner.VTable{ .run = commandRun };
        const workspace_vtable = ports.WorkspaceStore.VTable{
            .read = workspaceRead,
            .write = workspaceWrite,
        };
        const scanner_vtable = ports.WorkspaceScanner.VTable{ .scan_zig_files = scanZigFiles };
        const cache_vtable = ports.StaticCache.VTable{
            .status = cacheStatus,
            .load = cacheLoad,
            .store = cacheStore,
            .record_hit = cacheHit,
        };
    };

    var token: u8 = 0;
    const ctx = Context{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .tool_paths = .{ .zlint = "/bin/zlint" },
        .ports = .{
            .command_runner = .{ .ptr = &token, .vtable = &Stub.command_vtable },
            .workspace = .{ .ptr = &token, .vtable = &Stub.workspace_vtable },
            .workspace_scanner = .{ .ptr = &token, .vtable = &Stub.scanner_vtable },
            .semantic_index_cache = .{ .ptr = &token, .vtable = &Stub.cache_vtable },
        },
    };

    const static_ctx = try ctx.staticAnalysis();
    try std.testing.expect(static_ctx.command_runner != null);
    try std.testing.expect(static_ctx.semantic_index_cache != null);
    try std.testing.expectEqualStrings("/bin/zlint", static_ctx.tool_paths.zlint);

    const command = try static_ctx.command_runner.?.run(std.testing.allocator, .{ .argv = &.{"zig"} });
    defer command.deinit(std.testing.allocator);
    const read = try static_ctx.workspace_store.read(std.testing.allocator, .{ .path = "src/lib.zig" });
    defer read.deinit(std.testing.allocator);
    const write = try static_ctx.workspace_store.write(.{ .path = "src/lib.zig", .bytes = "pub fn lib() void {}" });
    try std.testing.expectEqual(@as(usize, 20), write.bytes_written);
    const scan = try static_ctx.workspace_scanner.scanZigFiles(std.testing.allocator, .{});
    defer scan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), scan.files.len);
    const status = try static_ctx.semantic_index_cache.?.status();
    try std.testing.expectEqual(@as(u64, 99), status.signature);
    const loaded = try static_ctx.semantic_index_cache.?.load(std.testing.allocator);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{}", loaded.bytes.?);
    const stored = try static_ctx.semantic_index_cache.?.store(std.testing.allocator, .{ .signature = 7, .bytes = "[]" });
    try std.testing.expectEqual(@as(u64, 7), stored.signature);
    const hit = try static_ctx.semantic_index_cache.?.recordHit();
    try std.testing.expectEqual(@as(usize, 1), hit.hits);
}
