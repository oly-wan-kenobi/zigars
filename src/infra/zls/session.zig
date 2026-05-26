const logging = @import("../observability/logging.zig");
const observability = @import("../observability/state.zig");
const uri_util = @import("uri.zig");
const DocumentState = @import("documents.zig").DocumentState;
const LspClient = @import("client.zig").LspClient;
const ZlsProcess = @import("process.zig").ZlsProcess;

const Allocator = @import("std").mem.Allocator;
const fs = @import("std").fs;
const heap = @import("std").heap;
const Io = @import("std").Io;
const mem = @import("std").mem;
const testing = @import("std").testing;

pub const Slots = struct {
    process: ?*?ZlsProcess = null,
    client: ?*?LspClient = null,
    documents: ?*?DocumentState = null,

    fn require(self: Slots) !RequiredSlots {
        return .{
            .process = self.process orelse return error.NotConnected,
            .client = self.client orelse return error.NotConnected,
            .documents = self.documents orelse return error.NotConnected,
        };
    }
};

const RequiredSlots = struct {
    process: *?ZlsProcess,
    client: *?LspClient,
    documents: *?DocumentState,
};

pub const Config = struct {
    allocator: Allocator,
    io: Io,
    workspace_root: []const u8,
    zls_path: []const u8,
    zls_timeout_ms: i64,
    logger: logging.Logger = .disabled(),
    observability: ?*observability.State = null,
};

pub const State = struct {
    process: ?*ZlsProcess = null,
    client: ?*LspClient = null,
    documents: ?*DocumentState = null,
    status: []const u8 = "not started",
    initialize_response: ?[]const u8 = null,
    last_failure: ?[]const u8 = null,
    restart_attempts: usize = 0,

    pub fn deinit(self: *State, allocator: Allocator) void {
        if (self.initialize_response) |bytes| allocator.free(bytes);
        self.* = .{};
    }

    pub fn running(self: State) bool {
        return if (self.client) |client| client.isRunning() else false;
    }
};

pub fn clear(state: *State) void {
    state.process = null;
    state.client = null;
    state.documents = null;
}

pub fn start(state: *State, slots: Slots, config: Config) !void {
    const required_slots = try slots.require();
    clear(state);
    required_slots.process.* = ZlsProcess.init(config.allocator, config.io, config.workspace_root, config.zls_path);
    errdefer {
        if (required_slots.process.*) |*proc| proc.deinit();
        required_slots.process.* = null;
    }
    try required_slots.process.*.?.spawn();

    const stdin = required_slots.process.*.?.getStdin() orelse return error.ZlsPipeUnavailable;
    const stdout = required_slots.process.*.?.getStdout() orelse return error.ZlsPipeUnavailable;
    const stderr = required_slots.process.*.?.getStderr();

    required_slots.client.* = LspClient.initWithTimeout(config.allocator, config.io, config.zls_timeout_ms);
    required_slots.client.*.?.setLogger(config.logger);
    errdefer {
        if (required_slots.client.*) |*client| client.deinit();
        required_slots.client.* = null;
    }
    try required_slots.client.*.?.connect(stdin, stdout, stderr);
    required_slots.process.*.?.detachPipes();

    const workspace_uri = try uri_util.pathToUri(config.allocator, config.workspace_root);
    defer config.allocator.free(workspace_uri);
    const response = try required_slots.client.*.?.initialize(config.allocator, workspace_uri);
    defer config.allocator.free(response);
    if (state.initialize_response) |old| config.allocator.free(old);
    state.initialize_response = try config.allocator.dupe(u8, response);

    const replay_existing_documents = required_slots.documents.* != null;
    if (required_slots.documents.* == null) {
        required_slots.documents.* = DocumentState.initWithIo(config.allocator, config.workspace_root, config.io);
    }
    required_slots.documents.*.?.setLogger(config.logger);

    state.process = &(required_slots.process.*.?);
    state.client = &(required_slots.client.*.?);
    state.documents = &(required_slots.documents.*.?);
    state.status = "connected";
    recordStatus(state, config);

    if (replay_existing_documents) {
        _ = required_slots.documents.*.?.reopenAll(&(required_slots.client.*.?));
    }
}

pub fn restart(state: *State, slots: Slots, config: Config) !void {
    const required_slots = try slots.require();

    if (required_slots.client.*) |*client| client.deinit();
    required_slots.client.* = null;
    if (required_slots.process.*) |*proc| proc.deinit();
    required_slots.process.* = null;

    clear(state);
    state.status = "restarting";
    state.restart_attempts += 1;
    recordStatus(state, config);
    start(state, slots, config) catch |err| {
        state.status = @errorName(err);
        state.last_failure = @errorName(err);
        recordStatus(state, config);
        return err;
    };
}

pub fn ensureReady(state: *State, slots: Slots, config: Config) !void {
    if (state.client) |client| {
        if (client.isRunning()) return;
    }
    try restart(state, slots, config);
}

fn recordStatus(state: *const State, config: Config) void {
    if (config.observability) |target| {
        target.recordZlsStatus(state.status, state.last_failure, state.restart_attempts);
    }
}
