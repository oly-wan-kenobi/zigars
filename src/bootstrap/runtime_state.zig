const std = @import("std");

const config_mod = @import("config.zig");
const doctor = @import("../app/usecases/environment/doctor.zig");
const logging = @import("../infra/observability/logging.zig");
const observability = @import("../infra/observability/state.zig");
const runtime_ux = @import("../infra/runtime_ux/state.zig");
const static_cache = @import("../infra/backends/static_cache.zig");
const workspace_mod = @import("../infra/workspace/workspace.zig");
const zls_session = @import("../infra/zls/session.zig");

/// Cached backend probe outcomes retained by bootstrap and exposed to app code as snapshots.
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
    temp_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// Releases runtime-owned caches, ZLS state, and parsed configuration.
    pub fn deinit(self: *App) void {
        self.analysis_cache.deinit(self.allocator);
        self.semantic_index_cache.deinit(self.allocator);
        self.zls.deinit(self.allocator);
        self.config.deinit(self.allocator);
    }
};
