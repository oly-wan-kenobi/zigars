//! Optional MCP client protocol helper requests.
const std = @import("std");
const mcp = @import("mcp");

const app_ports = @import("../../../app/ports.zig");
const mcp_result = @import("../result.zig");

const jsonrpc = mcp.jsonrpc;
const types = mcp.types;

/// Stable classifications for protocol-helper peer responses.
pub const ResponseStatus = enum {
    accepted,
    declined,
    cancelled,
    malformed,
    timeout,
};

/// Classifies an elicitation/create response without mutating server state.
pub fn classifyElicitationResponse(response: ?std.json.Value) ResponseStatus {
    const value = response orelse return .timeout;
    if (value != .object) return .malformed;
    const action = value.object.get("action") orelse return .malformed;
    if (action != .string) return .malformed;
    if (std.mem.eql(u8, action.string, "accept") or std.mem.eql(u8, action.string, "accepted")) {
        if (value.object.get("content")) |content| {
            if (content == .object) {
                if (content.object.get("confirm")) |confirm| {
                    if (confirm == .bool and !confirm.bool) return .declined;
                }
            }
        }
        return .accepted;
    }
    if (std.mem.eql(u8, action.string, "decline") or std.mem.eql(u8, action.string, "declined")) return .declined;
    if (std.mem.eql(u8, action.string, "cancel") or std.mem.eql(u8, action.string, "cancelled") or std.mem.eql(u8, action.string, "canceled")) return .cancelled;
    return .malformed;
}

/// Classifies a sampling/createMessage response without mutating server state.
pub fn classifySamplingResponse(response: ?std.json.Value) ResponseStatus {
    const value = response orelse return .timeout;
    if (value != .object) return .malformed;
    if (value.object.get("content")) |_| return .accepted;
    if (value.object.get("message")) |_| return .accepted;
    return .malformed;
}

/// Returns whether the initialized client advertised elicitation support.
pub fn supportsElicitation(server: anytype) bool {
    return server.client_capabilities != null and server.client_capabilities.?.elicitation != null;
}

/// Returns whether the initialized client advertised sampling support.
pub fn supportsSampling(server: anytype) bool {
    return server.client_capabilities != null and server.client_capabilities.?.sampling != null;
}

/// Sends elicitation/create when supported; otherwise returns a structured fallback.
pub fn tryElicitationCreate(server: anytype, io: std.Io, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    if (!supportsElicitation(server)) {
        return fallbackValue(allocator, "elicitation", "elicitation/create");
    }
    return sendClientRequestValue(server, io, allocator, "elicitation", "elicitation/create", params);
}

/// Sends sampling/createMessage when supported; otherwise returns a structured fallback.
pub fn trySamplingCreateMessage(server: anytype, io: std.Io, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    if (!supportsSampling(server)) {
        return fallbackValue(allocator, "sampling", "sampling/createMessage");
    }
    return sendClientRequestValue(server, io, allocator, "sampling", "sampling/createMessage", params);
}

/// Sends a protocol helper request to the active client and waits for its matching JSON-RPC response.
pub fn requestClientProtocol(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: app_ports.ProtocolRequest) !app_ports.ProtocolResponse {
    if (!supportsProtocolFeature(server, request.feature)) {
        return .{
            .supported = false,
            .used = false,
            .status = .unsupported,
            .unavailable_reason = unsupportedProtocolReason(request.feature),
        };
    }
    if (server.transport == null) {
        return .{
            .supported = true,
            .used = false,
            .status = .unsupported,
            .unavailable_reason = "no active MCP transport is available for protocol helper requests",
        };
    }

    const id = server.next_request_id;
    server.next_request_id += 1;
    try server.pending_requests.put(id, .{
        .method = request.method,
        .timestamp = @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_ms)),
    });
    defer _ = server.pending_requests.remove(id);

    const json_request = jsonrpc.createRequest(.{ .integer = id }, request.method, request.params);
    try server.sendResponse(io, allocator, .{ .request = json_request });

    while (true) {
        const message_data = server.transport.?.receive(io, allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EndOfStream => return .{
                .supported = true,
                .used = false,
                .status = .timeout,
                .unavailable_reason = "client protocol response was not available before the transport closed",
            },
            else => return .{
                .supported = true,
                .used = false,
                .status = .timeout,
                .unavailable_reason = "client protocol response was not available from the active transport",
            },
        };
        const data = message_data orelse return .{
            .supported = true,
            .used = false,
            .status = .timeout,
            .unavailable_reason = "client protocol response was not available on the active transport",
        };
        const parsed_message = jsonrpc.parseMessage(allocator, data) catch return .{
            .supported = true,
            .used = false,
            .status = .malformed,
            .unavailable_reason = "client protocol response was not valid JSON-RPC",
        };
        defer parsed_message.deinit();

        switch (parsed_message.message) {
            .response => |response| {
                if (!matchesRequestId(response.id, id)) {
                    server.handleResponse(response);
                    continue;
                }
                _ = server.pending_requests.remove(id);
                const status = classifyProtocolResponse(request.feature, response.result);
                return .{
                    .supported = true,
                    .used = status == .accepted,
                    .status = protocolStatus(status),
                    .result = if (response.result) |result| try mcp_result.cloneValue(allocator, result) else null,
                    .owns_result = response.result != null,
                    .unavailable_reason = unavailableReason(status),
                };
            },
            .error_response => |err| {
                if (!matchesOptionalRequestId(err.id, id)) {
                    server.handleErrorResponse(io, err);
                    continue;
                }
                _ = server.pending_requests.remove(id);
                return .{
                    .supported = true,
                    .used = false,
                    .status = .error_response,
                    .unavailable_reason = "client returned an error response for the protocol helper request",
                };
            },
            .request => |inbound_request| try rejectNestedRequest(server, io, allocator, inbound_request),
            .notification => |notification| try server.handleNotification(io, notification, data),
        }
    }
}

fn rejectNestedRequest(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    const error_response = jsonrpc.createErrorResponse(
        request.id,
        jsonrpc.ErrorCode.INVALID_REQUEST,
        "Server is awaiting a client protocol response; nested requests are not accepted",
        null,
    );
    try server.sendResponse(io, allocator, .{ .error_response = error_response });
}

/// App-facing protocol helper adapter bound to the currently executing tools/call.
pub fn Adapter(comptime ServerType: type) type {
    return struct {
        server: *ServerType,
        io: std.Io,

        const Self = @This();

        /// Builds a protocol helper adapter over the live MCP server and transport.
        pub fn init(server: *ServerType, io: std.Io) Self {
            return .{ .server = server, .io = io };
        }

        /// Projects this adapter as an app port.
        pub fn port(self: *Self) app_ports.ProtocolClient {
            return .{ .ptr = self, .vtable = &.{ .request = request } };
        }

        fn request(ptr: *anyopaque, allocator: std.mem.Allocator, request_value: app_ports.ProtocolRequest) app_ports.PortError!app_ports.ProtocolResponse {
            const self: *Self = @ptrCast(@alignCast(ptr));
            return self.server.requestClientProtocol(self.io, allocator, request_value) catch |err| switch (err) {
                error.OutOfMemory => app_ports.PortError.OutOfMemory,
            };
        }
    };
}

fn supportsProtocolFeature(server: anytype, feature: app_ports.ProtocolFeature) bool {
    return switch (feature) {
        .elicitation => supportsElicitation(server),
        .sampling => supportsSampling(server),
    };
}

fn classifyProtocolResponse(feature: app_ports.ProtocolFeature, response: ?std.json.Value) ResponseStatus {
    return switch (feature) {
        .elicitation => classifyElicitationResponse(response),
        .sampling => classifySamplingResponse(response),
    };
}

fn protocolStatus(status: ResponseStatus) app_ports.ProtocolResponseStatus {
    return switch (status) {
        .accepted => .accepted,
        .declined => .declined,
        .cancelled => .cancelled,
        .malformed => .malformed,
        .timeout => .timeout,
    };
}

fn unsupportedProtocolReason(feature: app_ports.ProtocolFeature) []const u8 {
    return switch (feature) {
        .elicitation => "client did not advertise MCP elicitation support",
        .sampling => "client did not advertise MCP sampling support",
    };
}

fn unavailableReason(status: ResponseStatus) []const u8 {
    return switch (status) {
        .accepted => "",
        .declined => "client declined the protocol helper request",
        .cancelled => "client cancelled the protocol helper request",
        .malformed => "client protocol helper response had an unsupported shape",
        .timeout => "client protocol helper response was not available",
    };
}

fn matchesRequestId(response_id: types.RequestId, expected: i64) bool {
    return switch (response_id) {
        .integer => |value| value == expected,
        .string => false,
    };
}

fn matchesOptionalRequestId(response_id: ?types.RequestId, expected: i64) bool {
    return if (response_id) |id| matchesRequestId(id, expected) else false;
}

fn fallbackValue(allocator: std.mem.Allocator, feature: []const u8, method: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "protocol_helper_fallback" });
    try obj.put(allocator, "feature", .{ .string = feature });
    try obj.put(allocator, "method", .{ .string = method });
    try obj.put(allocator, "supported", .{ .bool = false });
    try obj.put(allocator, "resolution", .{ .string = "Client did not advertise this optional MCP capability; continue with deterministic zigars arguments and structured tool results." });
    return .{ .object = obj };
}

fn sendClientRequestValue(server: anytype, io: std.Io, allocator: std.mem.Allocator, feature: []const u8, method: []const u8, params: std.json.Value) !std.json.Value {
    const id = server.next_request_id;
    server.next_request_id += 1;
    try server.pending_requests.put(id, .{
        .method = method,
        .timestamp = @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_ms)),
    });
    errdefer _ = server.pending_requests.remove(id);
    const request = jsonrpc.createRequest(.{ .integer = id }, method, params);
    try server.sendResponse(io, allocator, .{ .request = request });

    var obj: std.json.ObjectMap = .empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "protocol_helper_request" });
    try obj.put(allocator, "feature", .{ .string = feature });
    try obj.put(allocator, "method", .{ .string = method });
    try obj.put(allocator, "supported", .{ .bool = true });
    try obj.put(allocator, "request_id", .{ .integer = id });
    return .{ .object = obj };
}
