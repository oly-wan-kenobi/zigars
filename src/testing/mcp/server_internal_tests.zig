//! Internal server tests covering rollback, transport error handling, cancellation,
//! and lifecycle state transitions.
//! Pins that: OOM during addResource/addPrompt rolls back; per-message receive
//! errors (e.g. MessageTooLarge) are skipped while stream-level errors
//! (ReadError, ConnectionClosed) shut the server down instead of busy-looping;
//! cancellation tokens fire only for cancellable requests; and
//! notifications/initialized only advances state from .initializing.

const std = @import("std");
const mcp = @import("mcp");
const server_mod = @import("../../adapters/mcp/server.zig");
const cancellation = @import("cancellation");
const correlation = @import("../../adapters/mcp/correlation.zig");
const observability_mod = @import("../../infra/observability/state.zig");

const Server = server_mod.Server;
const transport_mod = mcp.transport;

test "server rollback and transport error branches" {
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
        var server = Server.init(failing.allocator(), .{ .name = "rollback", .version = "1" });
        defer server.deinit();
        try std.testing.expectError(error.OutOfMemory, server.addResourceWithDeinit(.{
            .uri = "file:///rollback",
            .name = "Rollback",
            .handler = undefined,
        }, undefined));
        try std.testing.expect(!server.resources.contains("file:///rollback"));
    }
    {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
        var server = Server.init(failing.allocator(), .{ .name = "rollback", .version = "1" });
        defer server.deinit();
        try std.testing.expectError(error.OutOfMemory, server.addPromptWithDeinit(.{
            .name = "rollback",
            .handler = undefined,
        }, undefined));
        try std.testing.expect(!server.prompts.contains("rollback"));
    }

    const ErrorReceiveTransport = struct {
        calls: usize = 0,
        first_error: transport_mod.Transport.ReceiveError,

        fn transport(self: *@This()) transport_mod.Transport {
            return .{ .ptr = self, .vtable = &.{ .send = send, .receive = receive, .close = close } };
        }

        fn send(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8) transport_mod.Transport.SendError!void {}

        fn receive(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            if (self.calls == 1) return self.first_error;
            return error.EndOfStream;
        }

        fn close(_: *anyopaque) void {}
    };

    // MessageTooLarge consumes input before failing, so the loop skips the
    // message and keeps serving: a second receive call observes EndOfStream.
    var skip_transport: ErrorReceiveTransport = .{ .first_error = error.MessageTooLarge };
    var skip_server = Server.init(std.testing.allocator, .{ .name = "receive", .version = "1" });
    defer skip_server.deinit();
    try skip_server.runWithTransport(std.testing.io, std.testing.allocator, skip_transport.transport());
    try std.testing.expectEqual(@as(usize, 2), skip_transport.calls);
    try skip_transport.transport().send(std.testing.io, std.testing.allocator, "{}");
    skip_transport.transport().close();

    // Stream-level errors mean no further message can ever arrive; the server
    // must shut down after the first call instead of retrying in a hot loop.
    for ([_]transport_mod.Transport.ReceiveError{ error.ReadError, error.ConnectionClosed }) |fatal_error| {
        var fatal_transport: ErrorReceiveTransport = .{ .first_error = fatal_error };
        var fatal_server = Server.init(std.testing.allocator, .{ .name = "receive-fatal", .version = "1" });
        defer fatal_server.deinit();
        try fatal_server.runWithTransport(std.testing.io, std.testing.allocator, fatal_transport.transport());
        try std.testing.expectEqual(@as(usize, 1), fatal_transport.calls);
    }

    const ErrorSendTransport = struct {
        fn transport(self: *@This()) transport_mod.Transport {
            return .{ .ptr = self, .vtable = &.{ .send = send, .receive = receive, .close = close } };
        }

        fn send(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8) transport_mod.Transport.SendError!void {
            return error.WriteError;
        }

        fn receive(_: *anyopaque, _: std.Io, _: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
            return error.EndOfStream;
        }

        fn close(_: *anyopaque) void {}
    };

    var send_transport: ErrorSendTransport = .{};
    var send_server = Server.init(std.testing.allocator, .{ .name = "send", .version = "1" });
    defer send_server.deinit();
    send_server.transport = send_transport.transport();
    try send_server.sendNotification(std.testing.io, std.testing.allocator, "notifications/test", null);
    try std.testing.expectError(error.EndOfStream, send_transport.transport().receive(std.testing.io, std.testing.allocator));
    send_transport.transport().close();

    var serialize_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try send_server.sendNotification(std.testing.io, serialize_failing.allocator(), "notifications/test", null);

    var stdio: transport_mod.StdioTransport = .{};
    send_server.stdio_transport = &stdio;
    Server.TestAccess.log(&send_server, std.testing.io, "log message");
    Server.TestAccess.logError(&send_server, std.testing.io, "log error");
    send_server.stdio_transport = null;
    stdio.deinit(std.testing.allocator);

    try send_server.pending_requests.put(1, .{ .method = "client/request", .timestamp = 1 });
    send_server.handleResponse(.{ .id = .{ .string = "string-id" }, .result = null });
    try std.testing.expect(send_server.pending_requests.contains(1));
    send_server.handleErrorResponse(std.testing.io, .{
        .id = .{ .string = "string-id" },
        .@"error" = .{ .code = -32603, .message = "client error" },
    });
    try std.testing.expect(send_server.pending_requests.contains(1));
}

test "server cancellation notifications mark active and completed requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = Server.init(std.testing.allocator, .{ .name = "cancel", .version = "1" });
    defer server.deinit();
    var state = observability_mod.State{};
    server.setObservability(state.recorder());

    var request_state = cancellation.State{};
    const active_id = correlation.RequestId.from(.{ .integer = 7 });
    server.active_request = .{
        .request_id = active_id,
        .method = "tools/call",
        .cancellable = true,
        .state = &request_state,
    };
    var params: std.json.ObjectMap = .empty;
    try params.put(allocator, "requestId", .{ .integer = 7 });
    try params.put(allocator, "reason", .{ .string = "client stopped waiting" });
    var notification_correlation = Server.TestAccess.nextCorrelation(&server, correlation.RequestId.absent(), "notifications/cancelled", null);
    Server.TestAccess.handleCancellationNotification(&server, std.testing.io, .{
        .method = "notifications/cancelled",
        .params = .{ .object = params },
    }, &notification_correlation);

    try std.testing.expect(request_state.token().isCancelled());
    try std.testing.expectEqualStrings("client stopped waiting", request_state.token().reason());
    try std.testing.expectEqual(@as(u64, 1), state.cancellation_requested);

    server.active_request = null;
    Server.TestAccess.rememberCompletedRequest(&server, correlation.RequestId.from(.{ .string = "done-1" }), "tools/call");
    var late_params: std.json.ObjectMap = .empty;
    try late_params.put(allocator, "requestId", .{ .string = "done-1" });
    Server.TestAccess.handleCancellationNotification(&server, std.testing.io, .{
        .method = "notifications/cancelled",
        .params = .{ .object = late_params },
    }, &notification_correlation);

    try std.testing.expectEqual(@as(u64, 2), state.cancellation_requested);
    try std.testing.expectEqual(@as(u64, 1), state.cancellation_completed);
    try std.testing.expectEqualStrings("completed_late", state.cancellation_events[1].status);
}

test "notifications/initialized only transitions to ready from initializing (LOW-2)" {
    var server = Server.init(std.testing.allocator, .{ .name = "lifecycle", .version = "1" });
    defer server.deinit();

    // A fresh server starts uninitialized. From .uninitialized (no prior
    // initialize), the notification must NOT force the server to .ready with
    // default client_info/capabilities.
    try std.testing.expect(server.state == .uninitialized);
    try server.handleNotification(std.testing.io, .{ .method = "notifications/initialized" }, null);
    try std.testing.expect(server.state == .uninitialized);

    // From .initializing (a successful initialize is in flight), the transition
    // is honored.
    server.state = .initializing;
    try server.handleNotification(std.testing.io, .{ .method = "notifications/initialized" }, null);
    try std.testing.expect(server.state == .ready);

    // A repeat notification after .ready does not regress or change state.
    try server.handleNotification(std.testing.io, .{ .method = "notifications/initialized" }, null);
    try std.testing.expect(server.state == .ready);

    // After shutdown, the notification must not resurrect the server to .ready.
    server.state = .shutting_down;
    try server.handleNotification(std.testing.io, .{ .method = "notifications/initialized" }, null);
    try std.testing.expect(server.state == .shutting_down);
}

test "server request cancellation metadata matches sequential transports" {
    try std.testing.expect(!Server.TestAccess.requestCanObserveCancellation("tools/call"));
    try std.testing.expect(!Server.TestAccess.requestCanObserveCancellation("completion/complete"));
    try std.testing.expect(!Server.TestAccess.requestCanObserveCancellation("resources/read"));
    try std.testing.expect(!Server.TestAccess.requestCanObserveCancellation("prompts/get"));

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = Server.init(std.testing.allocator, .{ .name = "cancel", .version = "1" });
    defer server.deinit();
    var state = observability_mod.State{};
    server.setObservability(state.recorder());

    var request_state = cancellation.State{};
    server.active_request = .{
        .request_id = correlation.RequestId.from(.{ .integer = 9 }),
        .method = "tools/call",
        .cancellable = Server.TestAccess.requestCanObserveCancellation("tools/call"),
        .state = &request_state,
    };

    var params: std.json.ObjectMap = .empty;
    try params.put(allocator, "requestId", .{ .integer = 9 });
    var notification_correlation = Server.TestAccess.nextCorrelation(&server, correlation.RequestId.absent(), "notifications/cancelled", null);
    Server.TestAccess.handleCancellationNotification(&server, std.testing.io, .{
        .method = "notifications/cancelled",
        .params = .{ .object = params },
    }, &notification_correlation);

    try std.testing.expect(!request_state.token().isCancelled());
    try std.testing.expectEqual(@as(u64, 1), state.cancellation_requested);
    try std.testing.expectEqual(@as(u64, 1), state.cancellation_uncancellable);
    try std.testing.expectEqualStrings("not_cancellable", state.cancellation_events[0].status);
}
