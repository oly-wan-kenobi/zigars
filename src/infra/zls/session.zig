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

test "clear drops ZLS pointers" {
    var fake_proc: ZlsProcess = undefined;
    var fake_client: LspClient = undefined;
    var fake_docs: DocumentState = undefined;
    var state = State{
        .process = &fake_proc,
        .client = &fake_client,
        .documents = &fake_docs,
    };

    clear(&state);
    try testing.expect(state.process == null);
    try testing.expect(state.client == null);
    try testing.expect(state.documents == null);
}

test "restart and ensureReady report missing slots" {
    var state = State{};
    const config = testConfig();
    try testing.expectError(error.NotConnected, restart(&state, .{}, config));
    try testing.expectError(error.NotConnected, ensureReady(&state, .{}, config));
}

test "ensureReady returns when the existing client is running" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var threaded: Io.Threaded = .init(heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const pipes = try @import("client_test_support.zig").testPipe();
    defer pipes.read_end.close(io);
    defer pipes.write_end.close(io);

    var client = LspClient.init(testing.allocator, io);
    defer {
        client.zls_stdin = null;
        client.zls_stdout = null;
        client.deinit();
    }
    client.zls_stdin = pipes.write_end;
    client.zls_stdout = pipes.read_end;
    client.running.store(true, .release);

    var state = State{ .client = &client };
    try ensureReady(&state, .{}, testConfig());
    try testing.expect(state.client == &client);
}

test "start initializes through echoing LSP process and records observability" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;
    var threaded: Io.Threaded = .init(heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cat_path = try findExecutable(io, &.{ "/bin/cat", "/usr/bin/cat" });

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root");
    const root = try tmpRoot(allocator, io, tmp.sub_path[0..]);
    defer allocator.free(root);

    var proc_slot: ?ZlsProcess = null;
    var client_slot: ?LspClient = null;
    var docs_slot: ?DocumentState = null;
    defer {
        if (docs_slot) |*docs| docs.deinit();
        if (client_slot) |*client| client.deinit();
        if (proc_slot) |*proc| proc.deinit();
    }

    var observed = observability.State{};
    var state = State{ .initialize_response = try allocator.dupe(u8, "old response") };
    defer state.deinit(allocator);
    try start(&state, .{ .process = &proc_slot, .client = &client_slot, .documents = &docs_slot }, .{
        .allocator = allocator,
        .io = io,
        .workspace_root = root,
        .zls_path = cat_path,
        .zls_timeout_ms = 1000,
        .observability = &observed,
    });

    try testing.expectEqualStrings("connected", state.status);
    try testing.expect(state.initialize_response != null);
    try testing.expect(mem.indexOf(u8, state.initialize_response.?, "\"method\":\"initialize\"") != null);
    try testing.expect(docs_slot != null);
    try testing.expectEqual(@as(u64, 1), observed.zls_event_count);
}

test "start replays an existing document state and restart records startup failures" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = testing.allocator;
    var threaded: Io.Threaded = .init(heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cat_path = try findExecutable(io, &.{ "/bin/cat", "/usr/bin/cat" });
    const false_path = try findExecutable(io, &.{ "/bin/false", "/usr/bin/false" });

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root");
    const root = try tmpRoot(allocator, io, tmp.sub_path[0..]);
    defer allocator.free(root);

    var proc_slot: ?ZlsProcess = null;
    var client_slot: ?LspClient = null;
    var docs_slot: ?DocumentState = DocumentState.initWithIo(allocator, root, io);
    defer {
        if (docs_slot) |*slot_docs| slot_docs.deinit();
        if (client_slot) |*client| client.deinit();
        if (proc_slot) |*proc| proc.deinit();
    }

    var state = State{};
    defer state.deinit(allocator);
    try start(&state, .{ .process = &proc_slot, .client = &client_slot, .documents = &docs_slot }, .{
        .allocator = allocator,
        .io = io,
        .workspace_root = root,
        .zls_path = cat_path,
        .zls_timeout_ms = 1000,
    });
    try testing.expect(state.documents != null);

    var observed = observability.State{};
    try testing.expectError(error.NoResponse, restart(&state, .{ .process = &proc_slot, .client = &client_slot, .documents = &docs_slot }, .{
        .allocator = allocator,
        .io = io,
        .workspace_root = root,
        .zls_path = false_path,
        .zls_timeout_ms = 1,
        .observability = &observed,
    }));
}

fn testConfig() Config {
    return .{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace_root = "/tmp/zigar-zls-session-test",
        .zls_path = "zls",
        .zls_timeout_ms = 30_000,
    };
}

fn findExecutable(io: Io, candidates: []const []const u8) ![]const u8 {
    for (candidates) |candidate| {
        Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        return candidate;
    }
    return error.SkipZigTest;
}

test "findExecutable reports SkipZigTest when no candidate exists" {
    try testing.expectError(error.SkipZigTest, findExecutable(testing.io, &.{"/definitely/not/a/zigar-test-binary"}));
}

fn tmpRoot(allocator: Allocator, io: Io, tmp_sub_path: []const u8) ![]u8 {
    const rel_base = try fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path });
    defer allocator.free(rel_base);
    const base_z = try Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    return try fs.path.join(allocator, &.{ base_z[0..], "root" });
}
