//! Tests for the ZLS Gateway port facade.
//! Pins capability probing from the cached initialize response, sync
//! routing (dirty vs disk-open), raw request forwarding, and the
//! Unavailable error path when no client is connected.
const std = @import("std");
const Gateway = @import("gateway.zig").Gateway;
const zls_session = @import("session.zig");
const Workspace = @import("../workspace/workspace.zig").Workspace;

/// Creates a temporary workspace and seed document for ZLS gateway tests.
fn testWorkspace() Workspace {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .root = "/workspace",
        .cache_root = "/workspace/.zigars-cache",
    };
}

/// Creates a minimal ZLS session configuration for tests.
fn testConfig() zls_session.Config {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .workspace_root = "/workspace",
        .zls_path = "zls",
        .zls_timeout_ms = 30_000,
    };
}

/// Creates a temporary workspace root for tests.
fn tmpRoot(allocator: std.mem.Allocator, io: std.Io, tmp_sub_path: []const u8) ![]u8 {
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path });
    defer allocator.free(rel_base);
    const base = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    defer allocator.free(base);
    return try std.fs.path.join(allocator, &.{ base, "root" });
}

test "gateway capability reads initialized ZLS capability state" {
    const lsp_client_mod = @import("client.zig");
    var client = lsp_client_mod.LspClient.init(std.testing.allocator, std.testing.io);
    defer client.deinit();

    var workspace = testWorkspace();
    var state = zls_session.State{
        .client = &client,
        .initialize_response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"hoverProvider\":{},\"definitionProvider\":false}}}",
    };
    var gateway = Gateway.init(.{
        .allocator = std.testing.allocator,
        .workspace = &workspace,
        .state = &state,
        .config = testConfig(),
    });

    const hover = try gateway.port().capability(.{ .capability = "hoverProvider" });
    try std.testing.expect(hover.supported);
    try std.testing.expectEqualStrings("initialize_response", hover.basis);

    const definition = try gateway.port().capability(.{ .capability = "definitionProvider" });
    try std.testing.expect(!definition.supported);
    try std.testing.expectEqualStrings("definitionProvider", definition.capability);

    const missing = try gateway.port().capability(.{ .capability = "referencesProvider" });
    try std.testing.expect(!missing.supported);
}

test "gateway capability reports unavailable before a client is connected" {
    var workspace = testWorkspace();
    var state = zls_session.State{
        .initialize_response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":{\"hoverProvider\":true}}}",
    };
    var gateway = Gateway.init(.{
        .allocator = std.testing.allocator,
        .workspace = &workspace,
        .state = &state,
        .config = testConfig(),
    });

    try std.testing.expectError(error.Unavailable, gateway.port().capability(.{ .capability = "hoverProvider" }));
}

test "gateway syncs documents and forwards raw ZLS requests" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const lsp_client_mod = @import("client.zig");
    const documents_mod = @import("documents.zig");
    const support = @import("client_test_support.zig");
    const allocator = std.testing.allocator;
    var client_threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer client_threaded.deinit();
    var fake_threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer fake_threaded.deinit();
    const client_io = client_threaded.io();
    const fake_io = fake_threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(client_io, "root/src");
    try tmp.dir.writeFile(client_io, .{ .sub_path = "root/src/disk.zig", .data = "const disk = true;\n" });
    const root = try tmpRoot(allocator, client_io, tmp.sub_path[0..]);
    defer allocator.free(root);

    const to_server = try support.testPipe();
    const from_server = try support.testPipe();
    var fake = support.FakeZls{
        .allocator = std.heap.smp_allocator,
        .io = fake_io,
        .read_end = to_server.read_end,
        .write_end = from_server.write_end,
    };
    const fake_thread = try std.Thread.spawn(.{}, support.FakeZls.run, .{&fake});

    var client = lsp_client_mod.LspClient.init(allocator, client_io);
    defer client.deinit();
    try client.connect(to_server.write_end, from_server.read_end, null);
    defer {
        client.shutdown() catch {};
        fake_thread.join();
    }

    const init_response = try client.initialize(allocator, "file:///workspace");
    defer allocator.free(init_response);
    var docs = documents_mod.DocumentState.initWithIo(allocator, root, client_io);
    defer docs.deinit();
    var workspace = Workspace{
        .allocator = allocator,
        .io = client_io,
        .root = root,
        .cache_root = root,
    };
    var counter: usize = 0;
    var state = zls_session.State{
        .client = &client,
        .documents = &docs,
        .initialize_response = init_response,
    };
    var gateway = Gateway.init(.{
        .allocator = allocator,
        .workspace = &workspace,
        .state = &state,
        .config = testConfig(),
        .request_counter = &counter,
    });

    const synced = try gateway.port().sync(allocator, .{ .file = "src/live.zig", .content = "const live = true;\n" });
    defer synced.deinit(allocator);
    try std.testing.expectEqualStrings("sync_text", synced.basis);

    const opened = try gateway.port().sync(allocator, .{ .file = "src/disk.zig" });
    defer opened.deinit(allocator);
    try std.testing.expectEqualStrings("ensure_open", opened.basis);

    const response = try gateway.port().request(allocator, .{
        .method = "textDocument/hover",
        .payload = "{\"textDocument\":{\"uri\":\"file:///workspace/src/live.zig\"},\"position\":{\"line\":0,\"character\":6}}",
    });
    defer response.deinit(allocator);
    try std.testing.expectEqualStrings("textDocument/hover", response.method);
    try std.testing.expect(std.mem.indexOf(u8, response.payload, "fake hover") != null);
    try std.testing.expectEqual(@as(usize, 1), counter);
}
