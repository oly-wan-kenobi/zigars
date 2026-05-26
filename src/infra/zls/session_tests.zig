const std = @import("std");
const session = @import("session.zig");
const observability = @import("../observability/state.zig");
const DocumentState = @import("documents.zig").DocumentState;
const LspClient = @import("client.zig").LspClient;
const ZlsProcess = @import("process.zig").ZlsProcess;

const Allocator = std.mem.Allocator;
const fs = std.fs;
const heap = std.heap;
const Io = std.Io;
const mem = std.mem;
const testing = std.testing;
const Config = session.Config;
const State = session.State;
const clear = session.clear;
const restart = session.restart;
const ensureReady = session.ensureReady;
const start = session.start;

/// Creates a minimal ZLS session configuration for tests.
fn testConfig() Config {
    return .{
        .allocator = testing.allocator,
        .io = testing.io,
        .workspace_root = "/tmp/zigar-zls-session-test",
        .zls_path = "zls",
        .zls_timeout_ms = 30_000,
    };
}

/// Finds an executable in the test PATH fixture.
fn findExecutable(io: Io, candidates: []const []const u8) ![]const u8 {
    for (candidates) |candidate| {
        Io.Dir.accessAbsolute(io, candidate, .{}) catch continue;
        return candidate;
    }
    return error.SkipZigTest;
}

/// Creates a temporary workspace root for tests.
fn tmpRoot(allocator: Allocator, io: Io, tmp_sub_path: []const u8) ![]u8 {
    const rel_base = try fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path });
    defer allocator.free(rel_base);
    const base_z = try Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base_z);
    return try fs.path.join(allocator, &.{ base_z[0..], "root" });
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

test "findExecutable reports SkipZigTest when no candidate exists" {
    try testing.expectError(error.SkipZigTest, findExecutable(testing.io, &.{"/definitely/not/a/zigar-test-binary"}));
}
