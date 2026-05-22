const std = @import("std");

const ports = @import("ports.zig");

pub const ContextError = error{
    MissingPort,
};

pub const WorkspaceView = struct {
    root: []const u8 = "",
    cache_root: []const u8 = "",

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

pub const ZlsState = struct {
    status: []const u8 = "not started",
    initialize_response: ?[]const u8 = null,
    last_failure: ?[]const u8 = null,
    restart_attempts: usize = 0,

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

pub const CacheState = struct {
    backend_probe: BackendProbeCacheSnapshot = .{},
    analysis: CacheSnapshot = .{},
    semantic_index: CacheSnapshot = .{},
};

pub const PortSet = struct {
    command_runner: ?ports.CommandRunner = null,
    workspace: ?ports.WorkspaceStore = null,
    zls_gateway: ?ports.ZlsGateway = null,
    backend_probe: ?ports.BackendProbe = null,
    artifact_store: ?ports.ArtifactStore = null,
    observability: ?ports.ObservabilitySink = null,
    clock_and_ids: ?ports.ClockAndIds = null,

    pub fn hasEffects(self: PortSet) bool {
        return self.command_runner != null or
            self.workspace != null or
            self.zls_gateway != null or
            self.backend_probe != null or
            self.artifact_store != null or
            self.observability != null or
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
    artifact_store: ?ports.ArtifactStore = null,
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

pub const StaticAnalysisContext = struct {
    workspace: WorkspaceView,
    workspace_store: ports.WorkspaceStore,
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

pub const Context = struct {
    workspace: WorkspaceView = .{},
    tool_paths: ToolPaths = .{},
    timeouts: Timeouts = .{},
    zls_state: ZlsState = .{},
    ports: PortSet = .{},
    counters: CounterHandles = .{},
    caches: CacheState = .{},

    pub fn requireCommandRunner(self: Context) ContextError!ports.CommandRunner {
        return self.ports.command_runner orelse ContextError.MissingPort;
    }

    pub fn requireWorkspace(self: Context) ContextError!ports.WorkspaceStore {
        return self.ports.workspace orelse ContextError.MissingPort;
    }

    pub fn profiling(self: Context) ContextError!ProfilingContext {
        return .{
            .workspace = self.workspace,
            .tool_paths = self.tool_paths,
            .timeouts = self.timeouts,
            .command_runner = try self.requireCommandRunner(),
            .workspace_store = try self.requireWorkspace(),
            .backend_probe = self.ports.backend_probe,
            .artifact_store = self.ports.artifact_store,
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

    pub fn staticAnalysis(self: Context) ContextError!StaticAnalysisContext {
        return .{
            .workspace = self.workspace,
            .workspace_store = try self.requireWorkspace(),
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
    try std.testing.expect(state.analysis.cached);
    try std.testing.expectEqual(@as(u64, 42), state.analysis.signature);
}
