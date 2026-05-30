//! Process-wide runtime state owned by bootstrap for the lifetime of the server.
//! App use cases receive a projected Context snapshot, never a direct pointer to App.
const std = @import("std");

const app_ports = @import("../app/ports.zig");
const config_mod = @import("config.zig");
const doctor = @import("../app/usecases/environment/doctor.zig");
const logging = @import("../infra/observability/logging.zig");
const observability = @import("../infra/observability/state.zig");
const runtime_ux = @import("../infra/runtime_ux/state.zig");
const static_cache = @import("../infra/backends/static_cache.zig");
const workspace_mod = @import("../infra/workspace/workspace.zig");
const zls_session = @import("../infra/zls/session.zig");

/// Cached backend probe outcomes retained by bootstrap and exposed to app code as snapshots.
/// Each slot is null until the first probe for that backend has completed.
pub const BackendProbeCache = struct {
    zig: ?doctor.Probe = null,
    zls: ?doctor.Probe = null,
    zlint: ?doctor.Probe = null,
    zwanzig: ?doctor.Probe = null,
    zflame: ?doctor.Probe = null,
    diff_folded: ?doctor.Probe = null,
};

/// Process-wide mutable runtime state owned by bootstrap.
/// App use cases receive projected Context values and ports instead of mutating this directly.
/// MCP handlers must receive an App pointer through user_data, not through a process-global.
pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    logger: logging.Logger = .disabled(),
    config: config_mod.Config,
    workspace: workspace_mod.Workspace,
    zls_slots: zls_session.Slots = .{},
    zls: zls_session.State = .{},
    command_calls: usize = 0,
    zls_requests: usize = 0,
    tool_errors: usize = 0,
    backend_probe_cache: BackendProbeCache = .{},
    analysis_cache: static_cache.State = .{},
    semantic_index_cache: static_cache.State = .{},
    observability: observability.State = .{},
    runtime_ux: runtime_ux.State = .{},
    protocol_client: ?app_ports.ProtocolClient = null,
    active_cancellation: ?app_ports.CancellationToken = null,
    temp_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Releases runtime-owned caches, ZLS state, and parsed configuration.
    /// Deinit order matches reverse dependency: caches before ZLS state before config.
    pub fn deinit(self: *App) void {
        self.analysis_cache.deinit(self.allocator);
        self.semantic_index_cache.deinit(self.allocator);
        self.zls.deinit(self.allocator);
        self.config.deinit(self.allocator);
    }
};
