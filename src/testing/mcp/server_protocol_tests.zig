//! Tests for server-side client-protocol request helpers (elicitation, sampling).
//! Pins the contracts for: capability-gated fallback when the client does not
//! advertise the feature; timeout termination when no matching response arrives;
//! nested inbound request rejection while waiting for a response; and
//! classifiers for accepted/declined/malformed/timeout response shapes.

const std = @import("std");
const mcp = @import("mcp");
const server_mod = @import("../../adapters/mcp/server.zig");
const app_ports = @import("../../app/ports.zig");
const mcp_result = @import("../../adapters/mcp/result.zig");

const Server = server_mod.Server;

// Scripted transport: replays a fixed message slice and captures sent frames.
const ScriptTransport = struct {
    messages: []const []const u8,
    index: usize = 0,
    sent: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *ScriptTransport, allocator: std.mem.Allocator) void {
        for (self.sent.items) |message| allocator.free(message);
        self.sent.deinit(allocator);
    }

    fn transport(self: *ScriptTransport) mcp.transport.Transport {
        return .{
            .ptr = self,
            .vtable = &.{ .send = sendVtable, .receive = receiveVtable, .close = closeVtable },
        };
    }

    fn sendVtable(ptr: *anyopaque, _: std.Io, allocator: std.mem.Allocator, message: []const u8) mcp.transport.Transport.SendError!void {
        const self: *ScriptTransport = @ptrCast(@alignCast(ptr));
        const owned = allocator.dupe(u8, message) catch return error.OutOfMemory;
        self.sent.append(allocator, owned) catch {
            allocator.free(owned);
            return error.OutOfMemory;
        };
    }

    fn receiveVtable(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator) mcp.transport.Transport.ReceiveError!?[]const u8 {
        const self: *ScriptTransport = @ptrCast(@alignCast(ptr));
        if (self.index >= self.messages.len) return error.EndOfStream;
        const message = self.messages[self.index];
        self.index += 1;
        return message;
    }

    fn closeVtable(_: *anyopaque) void {}
};

fn joinedSent(allocator: std.mem.Allocator, transport: *ScriptTransport) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (transport.sent.items) |message| {
        try out.appendSlice(allocator, message);
        try out.append(allocator, '\n');
    }
    return out.toOwnedSlice(allocator);
}

test "protocol helper scaffolds are capability aware" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server: Server = .init(allocator, .{ .name = "helper-server", .version = "1.0.0" });
    defer server.deinit();

    const fallback = try server.tryElicitationCreate(std.testing.io, allocator, .{ .object = .empty });
    try std.testing.expectEqualStrings("protocol_helper_fallback", fallback.object.get("kind").?.string);
    try std.testing.expect(!fallback.object.get("supported").?.bool);

    server.client_capabilities = .{
        .elicitation = .{ .form = .{} },
        .sampling = .{ .context = .{} },
    };
    var transport = ScriptTransport{ .messages = &.{} };
    defer transport.deinit(allocator);
    server.transport = transport.transport();

    var elicit_params = std.json.ObjectMap.empty;
    try elicit_params.put(allocator, "message", .{ .string = "Need value" });
    const elicit = try server.tryElicitationCreate(std.testing.io, allocator, .{ .object = elicit_params });
    try std.testing.expect(elicit.object.get("supported").?.bool);
    try std.testing.expect(server.pending_requests.contains(elicit.object.get("request_id").?.integer));

    var sampling_params = std.json.ObjectMap.empty;
    try sampling_params.put(allocator, "maxTokens", .{ .integer = 16 });
    const sampling = try server.trySamplingCreateMessage(std.testing.io, allocator, .{ .object = sampling_params });
    try std.testing.expect(sampling.object.get("supported").?.bool);
    try std.testing.expect(server.pending_requests.contains(sampling.object.get("request_id").?.integer));

    const sent = try joinedSent(allocator, &transport);
    try std.testing.expect(std.mem.indexOf(u8, sent, "elicitation/create") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "sampling/createMessage") != null);
}

test "protocol helper response classifiers cover declined malformed and timeout responses" {
    var elicited = std.json.ObjectMap.empty;
    try elicited.put(std.testing.allocator, "action", .{ .string = "accept" });
    defer elicited.deinit(std.testing.allocator);
    try std.testing.expectEqual(Server.ProtocolResponseStatus.accepted, Server.classifyElicitationResponse(.{ .object = elicited }));

    var declined = std.json.ObjectMap.empty;
    try declined.put(std.testing.allocator, "action", .{ .string = "decline" });
    defer declined.deinit(std.testing.allocator);
    try std.testing.expectEqual(Server.ProtocolResponseStatus.declined, Server.classifyElicitationResponse(.{ .object = declined }));

    var malformed = std.json.ObjectMap.empty;
    try malformed.put(std.testing.allocator, "action", .{ .integer = 1 });
    defer malformed.deinit(std.testing.allocator);
    try std.testing.expectEqual(Server.ProtocolResponseStatus.malformed, Server.classifyElicitationResponse(.{ .object = malformed }));
    try std.testing.expectEqual(Server.ProtocolResponseStatus.timeout, Server.classifyElicitationResponse(null));

    var sampled = std.json.ObjectMap.empty;
    try sampled.put(std.testing.allocator, "content", .{ .string = "summary" });
    defer sampled.deinit(std.testing.allocator);
    try std.testing.expectEqual(Server.ProtocolResponseStatus.accepted, Server.classifySamplingResponse(.{ .object = sampled }));
    try std.testing.expectEqual(Server.ProtocolResponseStatus.timeout, Server.classifySamplingResponse(null));
    try std.testing.expectEqual(Server.ProtocolResponseStatus.malformed, Server.classifySamplingResponse(.{ .object = .empty }));
}

test "client protocol request waits for matching elicitation response" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{ .name = "protocol", .version = "1" });
    defer server.deinit();
    server.state = .ready;
    server.client_capabilities = .{ .elicitation = .{ .form = .{} } };

    const messages = [_][]const u8{
        \\{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"p","progress":1}}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"action":"accept","content":{"confirm":true}}}
        ,
    };
    var transport = ScriptTransport{ .messages = &messages };
    defer transport.deinit(allocator);
    server.transport = transport.transport();

    var params = std.json.ObjectMap.empty;
    try params.put(allocator, "message", .{ .string = "Apply?" });
    defer params.deinit(allocator);
    const response = try server.requestClientProtocol(std.testing.io, allocator, .{
        .feature = .elicitation,
        .method = "elicitation/create",
        .params = .{ .object = params },
    });
    try std.testing.expect(response.supported);
    try std.testing.expect(response.used);
    try std.testing.expectEqual(app_ports.ProtocolResponseStatus.accepted, response.status);
    try std.testing.expect(response.result != null);
    if (response.result) |result| mcp_result.deinitOwnedValue(allocator, result);
    try std.testing.expectEqual(@as(usize, 0), server.pending_requests.count());

    const sent = try joinedSent(allocator, &transport);
    defer allocator.free(sent);
    try std.testing.expect(std.mem.indexOf(u8, sent, "elicitation/create") != null);
}

test "client protocol request rejects nested inbound requests while waiting for response" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{ .name = "protocol", .version = "1" });
    defer server.deinit();
    server.state = .ready;
    server.client_capabilities = .{ .elicitation = .{ .form = .{} } };

    const messages = [_][]const u8{
        \\{"jsonrpc":"2.0","id":"nested","method":"ping"}
        ,
        \\{"jsonrpc":"2.0","id":1,"result":{"action":"accept","content":{"confirm":true}}}
        ,
    };
    var transport = ScriptTransport{ .messages = &messages };
    defer transport.deinit(allocator);
    server.transport = transport.transport();

    var params = std.json.ObjectMap.empty;
    try params.put(allocator, "message", .{ .string = "Apply?" });
    defer params.deinit(allocator);
    const response = try server.requestClientProtocol(std.testing.io, allocator, .{
        .feature = .elicitation,
        .method = "elicitation/create",
        .params = .{ .object = params },
    });
    try std.testing.expect(response.supported);
    try std.testing.expect(response.used);
    try std.testing.expectEqual(app_ports.ProtocolResponseStatus.accepted, response.status);
    if (response.result) |result| mcp_result.deinitOwnedValue(allocator, result);
    try std.testing.expectEqual(@as(usize, 0), server.pending_requests.count());

    const sent = try joinedSent(allocator, &transport);
    defer allocator.free(sent);
    try std.testing.expect(std.mem.indexOf(u8, sent, "elicitation/create") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"id\":\"nested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "nested requests are not accepted") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"result\":{}") == null);
}

/// Transport that never closes and always returns a non-matching notification
/// frame, modelling a client that streams unrelated traffic without ever
/// replying to the server's protocol request. Without a deadline the wait loop
/// would live-lock; the deadline must terminate it (MEDIUM-2).
const StreamingNonMatchingTransport = struct {
    receives: usize = 0,
    frame: []const u8 =
        \\{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"p","progress":1}}
    ,

    fn transport(self: *StreamingNonMatchingTransport) mcp.transport.Transport {
        return .{
            .ptr = self,
            .vtable = &.{ .send = sendVtable, .receive = receiveVtable, .close = closeVtable },
        };
    }

    fn sendVtable(_: *anyopaque, _: std.Io, _: std.mem.Allocator, _: []const u8) mcp.transport.Transport.SendError!void {}

    fn receiveVtable(ptr: *anyopaque, _: std.Io, _: std.mem.Allocator) mcp.transport.Transport.ReceiveError!?[]const u8 {
        const self: *StreamingNonMatchingTransport = @ptrCast(@alignCast(ptr));
        self.receives += 1;
        // Borrow the static frame (matching ScriptTransport's convention); the
        // wait loop does not own/free received frames.
        return self.frame;
    }

    fn closeVtable(_: *anyopaque) void {}
};

test "client protocol request terminates via timeout when the client never matches" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{ .name = "protocol", .version = "1" });
    defer server.deinit();
    server.state = .ready;
    server.client_capabilities = .{ .elicitation = .{ .form = .{} } };

    var transport = StreamingNonMatchingTransport{};
    server.transport = transport.transport();

    var params = std.json.ObjectMap.empty;
    try params.put(allocator, "message", .{ .string = "Apply?" });
    defer params.deinit(allocator);

    // A short timeout bounds the wait; without the deadline this loop would spin
    // on the non-matching frames forever (the test would hang).
    const response = try server.requestClientProtocol(std.testing.io, allocator, .{
        .feature = .elicitation,
        .method = "elicitation/create",
        .params = .{ .object = params },
        .timeout_ms = 25,
    });
    try std.testing.expect(response.supported);
    try std.testing.expect(!response.used);
    try std.testing.expectEqual(app_ports.ProtocolResponseStatus.timeout, response.status);
    // The wait consumed at least one streamed non-matching frame before the
    // deadline fired, proving the deadline (not EndOfStream) terminated the loop.
    try std.testing.expect(transport.receives >= 1);
    try std.testing.expectEqual(@as(usize, 0), server.pending_requests.count());
}

test "client protocol request returns unsupported and transport timeout metadata" {
    const allocator = std.testing.allocator;
    var server = Server.init(allocator, .{ .name = "protocol", .version = "1" });
    defer server.deinit();
    server.state = .ready;

    var params = std.json.ObjectMap.empty;
    try params.put(allocator, "message", .{ .string = "Apply?" });
    defer params.deinit(allocator);
    const unsupported = try server.requestClientProtocol(std.testing.io, allocator, .{
        .feature = .elicitation,
        .method = "elicitation/create",
        .params = .{ .object = params },
    });
    try std.testing.expect(!unsupported.supported);
    try std.testing.expectEqual(app_ports.ProtocolResponseStatus.unsupported, unsupported.status);

    server.client_capabilities = .{ .sampling = .{ .context = .{} } };
    const messages = [_][]const u8{};
    var transport = ScriptTransport{ .messages = &messages };
    defer transport.deinit(allocator);
    server.transport = transport.transport();
    var sampling_params = std.json.ObjectMap.empty;
    try sampling_params.put(allocator, "maxTokens", .{ .integer = 8 });
    defer sampling_params.deinit(allocator);
    const timeout = try server.requestClientProtocol(std.testing.io, allocator, .{
        .feature = .sampling,
        .method = "sampling/createMessage",
        .params = .{ .object = sampling_params },
    });
    try std.testing.expect(timeout.supported);
    try std.testing.expect(!timeout.used);
    try std.testing.expectEqual(app_ports.ProtocolResponseStatus.timeout, timeout.status);
    try std.testing.expectEqual(@as(usize, 0), server.pending_requests.count());
}
