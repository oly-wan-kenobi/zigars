const std = @import("std");
const client_mod = @import("client.zig");
const support = @import("client_test_support.zig");

const FakeZls = support.FakeZls;
const LspClient = client_mod.LspClient;
const LspTransport = @import("transport.zig").LspTransport;
const testPipe = support.testPipe;

fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
}

test "LspClient init creates disconnected client" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    try std.testing.expect(client.zls_stdin == null);
    try std.testing.expect(client.zls_stdout == null);
    try std.testing.expect(client.reader_thread == null);
    try std.testing.expect(client.running.load(.acquire) == false);
}

test "sendRequest returns NotConnected when disconnected" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    try std.testing.expectError(error.NotConnected, client.sendRequest(alloc, "textDocument/hover", .{}));
}

test "sendNotification returns NotConnected when disconnected" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    try std.testing.expectError(error.NotConnected, client.sendNotification(alloc, "textDocument/didOpen", .{}));
}

test "sendRawNotification returns NotConnected when disconnected" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    try std.testing.expectError(error.NotConnected, client.sendRawNotification(alloc, "initialized"));
}

test "sendRequest records RequestTimeout when ZLS does not respond" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const to_server = try testPipe();
    defer to_server.read_end.close(io);

    var client = LspClient.initWithTimeout(alloc, io, 1);
    client.zls_stdin = to_server.write_end;
    client.running.store(true, .release);
    defer {
        if (client.zls_stdin) |stdin| {
            stdin.close(io);
            client.zls_stdin = null;
        }
        client.running.store(false, .release);
        client.deinit();
    }

    try std.testing.expectError(error.RequestTimeout, client.sendRequest(alloc, "textDocument/hover", .{}));
    const last = (try client.lastError(alloc)).?;
    defer alloc.free(last);
    try std.testing.expectEqualStrings("RequestTimeout", last);
}

test "sendRequest removes pending entry after timeout" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const to_server = try testPipe();
    defer to_server.read_end.close(io);

    var client = LspClient.initWithTimeout(alloc, io, 1);
    client.zls_stdin = to_server.write_end;
    client.running.store(true, .release);
    defer {
        if (client.zls_stdin) |stdin| {
            stdin.close(io);
            client.zls_stdin = null;
        }
        client.running.store(false, .release);
        client.deinit();
    }

    try std.testing.expectError(error.RequestTimeout, client.sendRequest(alloc, "textDocument/hover", .{}));
    try std.testing.expectEqual(@as(u32, 0), client.pending.count());
}

test "reader EOF stops LSP client and records EndOfStream" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const to_server = try testPipe();
    const from_server = try testPipe();
    defer to_server.read_end.close(io);

    var client = LspClient.init(alloc, io);
    defer client.deinit();
    try client.connect(to_server.write_end, from_server.read_end, null);
    from_server.write_end.close(io);

    std.Io.Timeout.sleep(.{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(20), .clock = .awake } }, io) catch {};
    try std.testing.expect(!client.isRunning());
    const last = (try client.lastError(alloc)).?;
    defer alloc.free(last);
    try std.testing.expectEqualStrings("EndOfStream", last);
}

test "reader transport errors stop LSP client and record last error" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const to_server = try testPipe();
    const from_server = try testPipe();
    defer to_server.read_end.close(io);

    var client = LspClient.init(alloc, io);
    defer client.deinit();
    client.setLogger(.disabled());
    try client.connect(to_server.write_end, from_server.read_end, null);

    try from_server.write_end.writeStreamingAll(io, "Bad-Header: 5\r\n\r\nhello");
    from_server.write_end.close(io);

    std.Io.Timeout.sleep(.{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(20), .clock = .awake } }, io) catch {};
    try std.testing.expect(!client.isRunning());
    const last = (try client.lastError(alloc)).?;
    defer alloc.free(last);
    try std.testing.expectEqualStrings("MissingContentLength", last);
}

test "reader ignores malformed JSON-RPC body without stopping" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const to_server = try testPipe();
    const from_server = try testPipe();
    defer to_server.read_end.close(io);

    var client = LspClient.init(alloc, io);
    defer client.deinit();
    client.setLogger(.disabled());
    try client.connect(to_server.write_end, from_server.read_end, null);

    try LspTransport.writeMessage(from_server.write_end, io, "{not json");
    std.Io.Timeout.sleep(.{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(20), .clock = .awake } }, io) catch {};
    try std.testing.expect(client.isRunning());
    from_server.write_end.close(io);
}

test "stderr reader drains stderr and disconnect joins it" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const to_server = try testPipe();
    const from_server = try testPipe();
    const stderr_pipe = try testPipe();
    defer to_server.read_end.close(io);

    var client = LspClient.init(alloc, io);
    defer client.deinit();
    client.setLogger(.disabled());
    client.shutdown_timeout_ms = 1;
    try client.connect(to_server.write_end, from_server.read_end, stderr_pipe.read_end);

    try stderr_pipe.write_end.writeStreamingAll(io, "zls stderr noise");
    std.Io.Timeout.sleep(.{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(20), .clock = .awake } }, io) catch {};
    stderr_pipe.write_end.close(io);
    from_server.write_end.close(io);
    std.Io.Timeout.sleep(.{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(20), .clock = .awake } }, io) catch {};

    client.disconnect();
    try std.testing.expect(client.stderr_thread == null);
    try std.testing.expect(client.zls_stderr == null);
}

test "disconnect on already disconnected client is safe" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    client.disconnect();
    client.disconnect();
}

test "disconnect uses teardown timeout instead of request timeout" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const to_server = try testPipe();
    defer to_server.read_end.close(io);

    var client = LspClient.initWithTimeout(alloc, io, 60_000);
    defer client.deinit();
    client.zls_stdin = to_server.write_end;
    client.running.store(true, .release);
    client.shutdown_timeout_ms = 1;

    const started_ns = std.Io.Clock.now(.real, io).nanoseconds;
    client.disconnect();
    const elapsed_ns = std.Io.Clock.now(.real, io).nanoseconds - started_ns;

    try std.testing.expect(elapsed_ns < std.time.ns_per_s);
    try std.testing.expect(!client.running.load(.acquire));
    try std.testing.expect(client.zls_stdin == null);
    try std.testing.expectEqual(@as(u32, 0), client.pending.count());
}

test "LspClient fake ZLS hover and diagnostics roundtrip" {
    const alloc = std.testing.allocator;
    var client_threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer client_threaded.deinit();
    var fake_threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer fake_threaded.deinit();
    const client_io = client_threaded.io();
    const fake_io = fake_threaded.io();
    const to_server = try testPipe();
    const from_server = try testPipe();

    var fake = FakeZls{
        .allocator = std.heap.smp_allocator,
        .io = fake_io,
        .read_end = to_server.read_end,
        .write_end = from_server.write_end,
    };
    const fake_thread = try std.Thread.spawn(.{}, FakeZls.run, .{&fake});

    var client = LspClient.init(alloc, client_io);
    defer client.deinit();
    try client.connect(to_server.write_end, from_server.read_end, null);

    const init_response = try client.initialize(alloc, "file:///tmp/quote\"slash\\root");
    defer alloc.free(init_response);
    try std.testing.expect(std.mem.indexOf(u8, init_response, "hoverProvider") != null);

    try client.sendNotification(alloc, "textDocument/didOpen", .{
        .textDocument = .{
            .uri = "file:///tmp/fake.zig",
            .languageId = "zig",
            .version = 1,
            .text = "const x = 1;\n",
        },
    });

    const hover_response = try client.sendRequest(alloc, "textDocument/hover", .{
        .textDocument = .{ .uri = "file:///tmp/fake.zig" },
        .position = .{ .line = 0, .character = 6 },
    });
    defer alloc.free(hover_response);
    try std.testing.expect(std.mem.indexOf(u8, hover_response, "fake hover") != null);

    const diagnostics = try client.getDiagnostics(alloc, "file:///tmp/fake.zig");
    try std.testing.expect(diagnostics != null);
    defer alloc.free(diagnostics.?);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics.?, "fake warning") != null);

    try client.shutdown();
    fake_thread.join();
}
