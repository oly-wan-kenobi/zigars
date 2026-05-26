const std = @import("std");

const app_context = @import("../app/context.zig");
const infra = @import("../infra/root.zig");
const runtime_mod = @import("runtime_state.zig");

const app_context_bridge = @import("app_context.zig");
const manifest_catalog = @import("manifest_catalog.zig");

pub const Options = struct {
    workspace_read_resolution: infra.workspace.filesystem.ReadResolution = .input,
    default_read_limit: usize = @import("../infra/process/command.zig").output_limit,
    non_exited_exit_code: i32 = -1,
    count_command_calls: bool = true,
    record_command_observability: bool = false,
};

pub const RuntimePorts = struct {
    app: *runtime_mod.App,
    command_runner: infra.process.command_runner.Runner,
    workspace_store: infra.workspace.filesystem.Store,
    workspace_scanner: infra.workspace.scanner.Scanner,
    backend_probe: infra.backends.probe.Runner,
    analysis_cache: infra.backends.static_cache.Cache,
    semantic_index_cache: infra.backends.static_cache.Cache,
    toolchain_env: infra.toolchain.env.Env,
    release_docs_scanner: infra.release.docs_scanner.Scanner,
    observability_reader: infra.observability.metrics.Reader,
    clock_and_ids: infra.clock.clock_and_ids.RuntimeClockAndIds,
    artifact_store: infra.artifacts.registry_store.Store,
    zls_gateway: infra.zls.gateway.Gateway,
    runtime_session: infra.runtime_ux.session.Session,
    tool_catalog: infra.runtime_ux.catalog.Catalog,
    tool_manifest: manifest_catalog.Catalog,

    const Self = @This();

    pub fn init(app: *runtime_mod.App, options: Options) Self {
        var result = Self{
            .app = app,
            .command_runner = infra.process.command_runner.Runner.init(.{
                .io = app.io,
                .default_cwd = app.workspace.root,
                .default_timeout_ms = app.config.timeout_ms,
                .command_calls = &app.command_calls,
                .tool_errors = &app.tool_errors,
                .observability = &app.observability,
                .count_command_calls = options.count_command_calls,
                .non_exited_exit_code = options.non_exited_exit_code,
                .record_observability = options.record_command_observability,
            }),
            .workspace_store = infra.workspace.filesystem.Store.init(&app.workspace, app.io, .{
                .default_read_limit = options.default_read_limit,
                .read_resolution = options.workspace_read_resolution,
            }),
            .workspace_scanner = infra.workspace.scanner.Scanner.init(&app.workspace, app.io),
            .backend_probe = undefined,
            .analysis_cache = infra.backends.static_cache.Cache.init(app.allocator, &app.analysis_cache),
            .semantic_index_cache = infra.backends.static_cache.Cache.init(app.allocator, &app.semantic_index_cache),
            .toolchain_env = infra.toolchain.env.Env.init(app.io, app.workspace.root, app.config.zig_path, app.config.timeout_ms),
            .release_docs_scanner = infra.release.docs_scanner.Scanner.init(&app.workspace, app.io),
            .observability_reader = infra.observability.metrics.Reader.init(&app.observability),
            .clock_and_ids = infra.clock.clock_and_ids.RuntimeClockAndIds.init(app.io, &app.temp_counter),
            .artifact_store = infra.artifacts.registry_store.Store.init(&app.workspace, app.io, .{
                .zig_path = app.config.zig_path,
                .zls_path = app.config.zls_path,
                .zflame_path = app.config.zflame_path,
                .diff_folded_path = app.config.diff_folded_path,
            }),
            .zls_gateway = infra.zls.gateway.Gateway.init(.{
                .allocator = app.allocator,
                .workspace = &app.workspace,
                .state = &app.zls,
                .slots = app.zls_slots,
                .config = .{
                    .allocator = app.allocator,
                    .io = app.io,
                    .workspace_root = app.workspace.root,
                    .zls_path = app.config.zls_path,
                    .zls_timeout_ms = app.config.zls_timeout_ms,
                    .logger = app.logger,
                    .observability = &app.observability,
                },
                .request_counter = &app.zls_requests,
            }),
            .runtime_session = infra.runtime_ux.session.Session.init(&app.runtime_ux),
            .tool_catalog = .{},
            .tool_manifest = .{},
        };
        result.backend_probe = infra.backends.probe.Runner.init(result.command_runner.port(), app.workspace.root, app.config.timeout_ms);
        return result;
    }

    pub fn refreshDerivedPorts(self: *Self) void {
        self.backend_probe = infra.backends.probe.Runner.init(self.command_runner.port(), self.app.workspace.root, self.app.config.timeout_ms);
    }

    pub fn portSet(self: *Self) app_context.PortSet {
        self.refreshDerivedPorts();
        return .{
            .command_runner = self.command_runner.port(),
            .workspace = self.workspace_store.port(),
            .workspace_scanner = self.workspace_scanner.port(),
            .backend_probe = self.backend_probe.port(),
            .analysis_cache = self.analysis_cache.port(),
            .semantic_index_cache = self.semantic_index_cache.port(),
            .toolchain_env = self.toolchain_env.port(),
            .docs_scanner = self.release_docs_scanner.port(),
            .observability_reader = self.observability_reader.port(),
            .artifact_store = self.artifact_store.port(),
            .runtime_session = self.runtime_session.port(),
            .tool_catalog = self.tool_catalog.port(),
            .tool_manifest = self.tool_manifest.port(),
            .clock_and_ids = self.clock_and_ids.port(),
            .zls_gateway = self.zls_gateway.port(),
        };
    }

    pub fn context(self: *Self) app_context.Context {
        return app_context_bridge.fromRuntime(self.app, self.portSet());
    }

    pub fn profilingContext(self: *Self) app_context.ContextError!app_context.ProfilingContext {
        return self.context().profiling();
    }

    pub fn performanceContext(self: *Self) app_context.ContextError!app_context.PerformanceContext {
        return self.context().performance();
    }

    pub fn diagnosticsContext(self: *Self) app_context.ContextError!app_context.DiagnosticsContext {
        return self.context().diagnostics();
    }

    pub fn releaseWorkflowContext(self: *Self) app_context.ContextError!app_context.ReleaseWorkflowContext {
        return self.context().releaseWorkflows();
    }

    pub fn environmentContext(self: *Self) app_context.ContextError!app_context.EnvironmentContext {
        return self.context().environment();
    }

    pub fn adoptionContext(self: *Self) app_context.ContextError!app_context.AdoptionContext {
        return self.context().adoption();
    }

    pub fn trustContext(self: *Self) app_context.ContextError!app_context.TrustContext {
        return self.context().trust();
    }

    pub fn coreContext(self: *Self) app_context.ContextError!app_context.CoreCommandContext {
        return self.context().coreCommands();
    }

    pub fn validationContext(self: *Self) app_context.ContextError!app_context.ValidationContext {
        return self.context().validation();
    }

    pub fn editingContext(self: *Self) app_context.ContextError!app_context.EditingContext {
        return self.context().editing();
    }

    pub fn artifactContext(self: *Self) app_context.ContextError!app_context.ArtifactContext {
        return self.context().artifacts();
    }

    pub fn zlsContext(self: *Self) app_context.ContextError!app_context.ZlsContext {
        return self.context().zls();
    }

    pub fn runtimeUxContext(self: *Self) app_context.ContextError!app_context.RuntimeUxContext {
        return self.context().runtimeUx();
    }

    pub fn observabilityContext(self: *Self) app_context.ContextError!app_context.ObservabilityContext {
        return self.context().observability();
    }

    pub fn projectIntelligenceContext(self: *Self) app_context.ContextError!app_context.ProjectIntelligenceContext {
        return self.context().projectIntelligence();
    }

    pub fn releaseDocsContext(self: *Self) app_context.ContextError!app_context.ReleaseDocsContext {
        return self.context().releaseDocs();
    }

    pub fn resolveInputPath(self: *Self, path: []const u8) ![]const u8 {
        return self.workspace_store.resolveInputPath(path);
    }

    pub fn resolveOutputPath(self: *Self, path: []const u8) ![]const u8 {
        return self.workspace_store.resolveOutputPath(path);
    }

    pub fn freeResolvedPath(self: *Self, path: []const u8) void {
        self.workspace_store.freeResolvedPath(path);
    }

    pub fn pathAllocator(self: *Self) std.mem.Allocator {
        return self.app.workspace.allocator;
    }
};
