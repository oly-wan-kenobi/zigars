const std = @import("std");

const config_mod = @import("config.zig");
const doctor = @import("doctor.zig");
const workspace_mod = @import("workspace.zig");
const LspClient = @import("lsp/client.zig").LspClient;
const DocumentState = @import("state/documents.zig").DocumentState;
const ZlsProcess = @import("zls/process.zig").ZlsProcess;

pub const BackendProbeCache = struct {
    zig: ?doctor.Probe = null,
    zls: ?doctor.Probe = null,
    zwanzig: ?doctor.Probe = null,
    zflame: ?doctor.Probe = null,
    diff_folded: ?doctor.Probe = null,
};

pub const AnalysisCache = struct {
    signature: u64 = 0,
    index_json: ?[]u8 = null,
    hits: usize = 0,
    refreshes: usize = 0,

    pub fn deinit(self: *AnalysisCache, allocator: std.mem.Allocator) void {
        if (self.index_json) |bytes| allocator.free(bytes);
        self.* = .{};
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: config_mod.Config,
    workspace: workspace_mod.Workspace,
    zls_process_slot: ?*?ZlsProcess = null,
    lsp_client_slot: ?*?LspClient = null,
    doc_state_slot: ?*?DocumentState = null,
    zls_process: ?*ZlsProcess = null,
    lsp_client: ?*LspClient = null,
    doc_state: ?*DocumentState = null,
    zls_status: []const u8 = "not started",
    zls_initialize_response: ?[]const u8 = null,
    zls_last_failure: ?[]const u8 = null,
    zls_restart_attempts: usize = 0,
    command_calls: usize = 0,
    zls_requests: usize = 0,
    tool_errors: usize = 0,
    backend_probe_cache: BackendProbeCache = .{},
    analysis_cache: AnalysisCache = .{},
    temp_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn deinit(self: *App) void {
        self.analysis_cache.deinit(self.allocator);
        if (self.zls_initialize_response) |bytes| {
            self.allocator.free(bytes);
            self.zls_initialize_response = null;
        }
        self.config.deinit(self.allocator);
    }
};
