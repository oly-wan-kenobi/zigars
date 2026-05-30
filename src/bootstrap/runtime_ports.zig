//! Wires concrete infra adapters into the app PortSet contract for a single server lifetime.
//! RuntimePorts borrows App state by pointer; the App must outlive all RuntimePorts values.
const std = @import("std");

const app_context = @import("../app/context.zig");
const infra = @import("../infra/root.zig");
const runtime_mod = @import("runtime_state.zig");

const app_context_bridge = @import("app_context.zig");
const manifest_catalog = @import("manifest_catalog.zig");

/// Tuning knobs applied when constructing infra adapters inside RuntimePorts.
/// Defaults are appropriate for MCP server mode; CLI callers override as needed.
pub const Options = struct {
    workspace_read_resolution: infra.workspace.filesystem.ReadResolution = .input,
    default_read_limit: usize = @import("../infra/process/command.zig").output_limit,
    non_exited_exit_code: i32 = -1,
    count_command_calls: bool = true,
    record_command_observability: bool = false,
};

/// Owns concrete infra adapters and projects them into the app PortSet contract.
/// The pointed-to App owns the underlying state and must outlive this value.
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

    /// Builds concrete ports over bootstrap-owned runtime state.
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
                .cancellation_token = app.active_cancellation,
                .count_command_calls = options.count_command_calls,
                .non_exited_exit_code = options.non_exited_exit_code,
                .record_observability = options.record_command_observability,
            }),
            .workspace_store = infra.workspace.filesystem.Store.init(&app.workspace, app.io, .{
                .default_read_limit = options.default_read_limit,
                .read_resolution = options.workspace_read_resolution,
                .cancellation_token = app.active_cancellation,
            }),
            .workspace_scanner = infra.workspace.scanner.Scanner.init(&app.workspace, app.io),
            // assigned below once command_runner.port() is available
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
                .cancellation_token = app.active_cancellation,
            }),
            .runtime_session = infra.runtime_ux.session.Session.init(&app.runtime_ux),
            .tool_catalog = .{},
            .tool_manifest = .{},
        };
        result.backend_probe = infra.backends.probe.Runner.init(result.command_runner.port(), app.workspace.root, app.config.timeout_ms);
        return result;
    }

    /// Rebinds ports whose dependencies can change after construction.
    /// Currently re-initialises backend_probe so command_runner and workspace changes propagate.
    pub fn refreshDerivedPorts(self: *Self) void {
        self.backend_probe = infra.backends.probe.Runner.init(self.command_runner.port(), self.app.workspace.root, self.app.config.timeout_ms);
    }

    /// Returns the app-facing port table for the current runtime state.
    pub fn portSet(self: *Self) app_context.PortSet {
        // Keep this logic centralized so callers observe one consistent behavior path.
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
            .protocol_client = self.app.protocol_client,
        };
    }

    /// Projects the current runtime into a read-only app Context plus live ports.
    pub fn context(self: *Self) app_context.Context {
        return app_context_bridge.fromRuntime(self.app, self.portSet());
    }

    /// Narrows the projected app context to profiling dependencies.
    pub fn profilingContext(self: *Self) app_context.ContextError!app_context.ProfilingContext {
        return self.context().profiling();
    }

    /// Narrows the projected app context to performance dependencies.
    pub fn performanceContext(self: *Self) app_context.ContextError!app_context.PerformanceContext {
        return self.context().performance();
    }

    /// Narrows the projected app context to diagnostics dependencies.
    pub fn diagnosticsContext(self: *Self) app_context.ContextError!app_context.DiagnosticsContext {
        return self.context().diagnostics();
    }

    /// Narrows the projected app context to release workflow dependencies.
    pub fn releaseWorkflowContext(self: *Self) app_context.ContextError!app_context.ReleaseWorkflowContext {
        return self.context().releaseWorkflows();
    }

    /// Narrows the projected app context to environment/toolchain dependencies.
    pub fn environmentContext(self: *Self) app_context.ContextError!app_context.EnvironmentContext {
        return self.context().environment();
    }

    /// Narrows the projected app context to adoption guidance dependencies.
    pub fn adoptionContext(self: *Self) app_context.ContextError!app_context.AdoptionContext {
        return self.context().adoption();
    }

    /// Narrows the projected app context to trust/probe dependencies.
    pub fn trustContext(self: *Self) app_context.ContextError!app_context.TrustContext {
        return self.context().trust();
    }

    /// Narrows the projected app context to core Zig command dependencies.
    pub fn coreContext(self: *Self) app_context.ContextError!app_context.CoreCommandContext {
        return self.context().coreCommands();
    }

    /// Narrows the projected app context to validation workflow dependencies.
    pub fn validationContext(self: *Self) app_context.ContextError!app_context.ValidationContext {
        return self.context().validation();
    }

    /// Narrows the projected app context to editing workflow dependencies.
    pub fn editingContext(self: *Self) app_context.ContextError!app_context.EditingContext {
        return self.context().editing();
    }

    /// Narrows the projected app context to artifact registry dependencies.
    pub fn artifactContext(self: *Self) app_context.ContextError!app_context.ArtifactContext {
        return self.context().artifacts();
    }

    /// Narrows the projected app context to ZLS dependencies.
    pub fn zlsContext(self: *Self) app_context.ContextError!app_context.ZlsContext {
        return self.context().zls();
    }

    /// Narrows the projected app context to runtime UX session dependencies.
    pub fn runtimeUxContext(self: *Self) app_context.ContextError!app_context.RuntimeUxContext {
        return self.context().runtimeUx();
    }

    /// Narrows the projected app context to observability reader dependencies.
    pub fn observabilityContext(self: *Self) app_context.ContextError!app_context.ObservabilityContext {
        return self.context().observability();
    }

    /// Narrows the projected app context to project intelligence dependencies.
    pub fn projectIntelligenceContext(self: *Self) app_context.ContextError!app_context.ProjectIntelligenceContext {
        return self.context().projectIntelligence();
    }

    /// Narrows the projected app context to release documentation dependencies.
    pub fn releaseDocsContext(self: *Self) app_context.ContextError!app_context.ReleaseDocsContext {
        return self.context().releaseDocs();
    }

    /// Resolves a workspace input path; caller owns the returned buffer.
    pub fn resolveInputPath(self: *Self, path: []const u8) ![]const u8 {
        return self.workspace_store.resolveInputPath(path);
    }

    /// Resolves a workspace output path; caller owns the returned buffer.
    pub fn resolveOutputPath(self: *Self, path: []const u8) ![]const u8 {
        return self.workspace_store.resolveOutputPath(path);
    }

    /// Frees a path returned by resolveInputPath or resolveOutputPath.
    pub fn freeResolvedPath(self: *Self, path: []const u8) void {
        self.workspace_store.freeResolvedPath(path);
    }

    /// Returns the allocator used for resolved workspace paths.
    pub fn pathAllocator(self: *Self) std.mem.Allocator {
        return self.app.workspace.allocator;
    }
};
