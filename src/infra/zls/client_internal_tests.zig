//! White-box tests for LspClient internals accessed via TestAccess.
//! Pins: timeout clamping, last-error replacement, duplicate-response handling,
//! allocation-failure path in storePendingResponseLocked, signal-all-pending,
//! exit-notification error classification, and shutdown via scripted pipe.
const std = @import("std");
const client_mod = @import("client.zig");
const logging = @import("../observability/logging.zig");

const access = client_mod.TestAccess;
const LspClient = client_mod.LspClient;
const LspTransport = @import("transport.zig").LspTransport;
const PendingRequest = access.Pending;
const testPipe = @import("client_test_support.zig").testPipe;

fn testIo() std.Io {
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    return threaded.io();
}

test "initWithTimeout clamps timeout and lastError returns owned copy" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.initWithTimeout(alloc, io, 0);
    defer client.deinit();

    try std.testing.expectEqual(@as(i64, 1), client.request_timeout_ms);
    try access.setLastError(&client, "RequestTimeout");
    const first = (try client.lastError(alloc)).?;
    defer alloc.free(first);
    try std.testing.expectEqualStrings("RequestTimeout", first);

    try access.setLastError(&client, "EndOfStream");
    const second = (try client.lastError(alloc)).?;
    defer alloc.free(second);
    try std.testing.expectEqualStrings("EndOfStream", second);
    try std.testing.expectEqualStrings("RequestTimeout", first);
}

test "duplicate LSP response replaces pending response buffer" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    const pending = try alloc.create(PendingRequest);
    pending.* = .{ .allocator = alloc };
    try client.pending.put(alloc, 7, pending);

    client.pending_mutex.lock();
    access.storePendingResponseLocked(&client, 7, "{\"id\":7,\"result\":\"first\"}");
    access.storePendingResponseLocked(&client, 7, "{\"id\":7,\"result\":\"second\"}");
    client.pending_mutex.unlock();

    const removed = access.takePending(&client, 7) orelse return error.TestUnexpectedResult;
    defer alloc.destroy(removed);
    defer if (removed.response) |response| alloc.free(response);
    try std.testing.expect(std.mem.indexOf(u8, removed.response.?, "second") != null);
}

test "setLogger swaps logger and disabled sink remains quiet" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    client.setLogger(logging.Logger.disabled());
    client.logger.warn("lsp", "ignored", .{});
}

test "storePendingResponseLocked handles allocation failure and signals waiter" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer {
        client.allocator = alloc;
        client.deinit();
    }
    client.setLogger(logging.Logger.disabled());

    const pending = try alloc.create(PendingRequest);
    pending.* = .{ .allocator = alloc };
    try client.pending.put(alloc, 11, pending);

    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    client.allocator = failing.allocator();

    client.pending_mutex.lock();
    access.storePendingResponseLocked(&client, 11, "{\"jsonrpc\":\"2.0\",\"id\":11,\"result\":true}");
    client.pending_mutex.unlock();

    client.allocator = alloc;
    try std.testing.expect(pending.response == null);
    try pending.event.waitTimeout(io, .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(1), .clock = .awake } });
}

test "signalAllPending wakes every outstanding request" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();

    const pending = try alloc.create(PendingRequest);
    pending.* = .{ .allocator = alloc };
    try client.pending.put(alloc, 21, pending);

    access.signalAllPending(&client);
    try pending.event.waitTimeout(io, .{ .duration = .{ .raw = std.Io.Duration.fromMilliseconds(1), .clock = .awake } });
}

test "exit notification error handler classifies benign and hard failures" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);
    defer client.deinit();
    client.setLogger(logging.Logger.disabled());

    client.running.store(true, .release);
    access.handleExitNotificationError(&client, error.NotConnected);
    try std.testing.expect(!client.running.load(.acquire));
    try std.testing.expect(try client.lastError(alloc) == null);

    client.running.store(true, .release);
    access.handleExitNotificationError(&client, error.AccessDenied);
    try std.testing.expect(client.running.load(.acquire));
    const last = (try client.lastError(alloc)).?;
    defer alloc.free(last);
    try std.testing.expectEqualStrings("AccessDenied", last);
}

test "shutdown treats missing exit pipe as benign after response" {
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const to_server = try testPipe();

    var client = LspClient.init(alloc, io);
    defer client.deinit();
    client.setLogger(logging.Logger.disabled());
    client.zls_stdin = to_server.write_end;
    client.running.store(true, .release);

    const Responder = struct {
        fn run(c: *LspClient, read_end: std.Io.File, thread_io: std.Io) void {
            // Keep this logic centralized so callers observe one consistent behavior path.
            defer read_end.close(thread_io);
            var reader = LspTransport.Reader.init(read_end, thread_io);
            const maybe_msg = reader.readMessage(std.heap.smp_allocator) catch return;
            if (maybe_msg) |msg| std.heap.smp_allocator.free(msg);

            c.pending_mutex.lock();
            defer c.pending_mutex.unlock();
            const pending = c.pending.get(1) orelse return;
            pending.response = c.allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}") catch return;
            if (c.zls_stdin) |stdin| {
                stdin.close(thread_io);
                c.zls_stdin = null;
            }
            pending.event.set(thread_io);
        }
    };

    const responder = try std.Thread.spawn(.{}, Responder.run, .{ &client, to_server.read_end, io });
    try access.shutdownWithTimeout(&client, 1000);
    responder.join();

    try std.testing.expect(!client.running.load(.acquire));
    try std.testing.expect(client.zls_stdin == null);
}

test "deinit releases pending response buffers" {
    const alloc = std.testing.allocator;
    const io = testIo();
    var client = LspClient.init(alloc, io);

    const pending = try alloc.create(PendingRequest);
    pending.* = .{
        .allocator = alloc,
        .response = try alloc.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":31,\"result\":null}"),
    };
    try client.pending.put(alloc, 31, pending);

    client.deinit();
}

test "closed exit notification is benign after shutdown response" {
    try std.testing.expect(access.benignExitNotificationError(error.BrokenPipe));
    try std.testing.expect(access.benignExitNotificationError(error.EndOfStream));
    try std.testing.expect(access.benignExitNotificationError(error.NotConnected));
    try std.testing.expect(!access.benignExitNotificationError(error.RequestTimeout));
}
