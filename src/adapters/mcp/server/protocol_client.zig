//! Optional MCP client protocol helper requests.
const std = @import("std");
const mcp = @import("mcp");

const app_ports = @import("../../../app/ports.zig");
const mcp_result = @import("../result.zig");

const jsonrpc = mcp.jsonrpc;
const types = mcp.types;

/// Default deadline applied to a server→client protocol request when the caller
/// leaves `timeout_ms` unset. The serial transport means a silent or streaming
/// client would otherwise wedge the whole server (MEDIUM-2); this bounds the
/// wait. 30s is generous for an interactive elicitation/sampling reply.
pub const default_timeout_ms: u64 = 30_000;

/// Stable classifications for protocol-helper peer responses.
pub const ResponseStatus = enum {
    /// Client affirmatively answered (elicitation accept / sampling content).
    accepted,
    /// Client refused, or accepted an elicitation with `confirm: false`.
    declined,
    /// Client explicitly cancelled the request.
    cancelled,
    /// Response was present but did not match the expected shape.
    malformed,
    /// No usable response before the deadline or transport close.
    timeout,
};

/// Classifies an elicitation/create response without mutating server state.
pub fn classifyElicitationResponse(response: ?std.json.Value) ResponseStatus {
    const value = response orelse return .timeout;
    if (value != .object) return .malformed;
    const action = value.object.get("action") orelse return .malformed;
    if (action != .string) return .malformed;
    // Accept multiple spellings since clients differ. An explicit
    // `content.confirm: false` inside an accept is a negative confirmation, so
    // it is treated as declined rather than a true acceptance.
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

/// Returns whether the initialized client advertised roots support.
pub fn supportsRoots(server: anytype) bool {
    return server.client_capabilities != null and server.client_capabilities.?.roots != null;
}

/// Classifies a roots/list response without mutating server state. Accepted iff
/// the result carries a `roots` array (possibly empty, which is a valid "no
/// roots" answer); anything else is malformed, and a null result is a timeout.
pub fn classifyRootsResponse(response: ?std.json.Value) ResponseStatus {
    const value = response orelse return .timeout;
    if (value != .object) return .malformed;
    const roots = value.object.get("roots") orelse return .malformed;
    if (roots != .array) return .malformed;
    return .accepted;
}

/// Fire-and-return-handle elicitation/create. When the client advertised
/// elicitation, sends the request and returns a descriptor with the outbound
/// `request_id` (the reply is not awaited here); otherwise returns a structured
/// "unsupported" fallback. Use `requestClientProtocol` for a synchronous,
/// deadline-bounded round trip.
pub fn tryElicitationCreate(server: anytype, io: std.Io, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    if (!supportsElicitation(server)) {
        return fallbackValue(allocator, "elicitation", "elicitation/create");
    }
    return sendClientRequestValue(server, io, allocator, "elicitation", "elicitation/create", params);
}

/// Fire-and-return-handle sampling/createMessage; see `tryElicitationCreate`.
/// Returns a request descriptor when supported, else an "unsupported" fallback.
pub fn trySamplingCreateMessage(server: anytype, io: std.Io, allocator: std.mem.Allocator, params: std.json.Value) !std.json.Value {
    if (!supportsSampling(server)) {
        return fallbackValue(allocator, "sampling", "sampling/createMessage");
    }
    return sendClientRequestValue(server, io, allocator, "sampling", "sampling/createMessage", params);
}

/// Sends a server→client protocol helper request and blocks for its matching
/// reply, returning a structured outcome instead of erroring on declines/timeouts.
///
/// Returns early (status `unsupported`) when the feature was not advertised or
/// no transport is attached. Otherwise it allocates an outbound id, sends, and
/// drains the serial transport against a deadline: frames not matching this id
/// are dispatched normally (peer responses cleared, notifications handled) and
/// nested inbound requests are rejected, so it neither deadlocks nor mis-binds a
/// stray frame. An accepted result is cloned into `allocator` (`owns_result`).
pub fn requestClientProtocol(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: app_ports.ProtocolRequest) !app_ports.ProtocolResponse {
    if (!supportsProtocolFeature(server, request.feature)) {
        return .{
            .supported = false,
            .used = false,
            .status = .unsupported,
            .unavailable_reason = unsupportedProtocolReason(request.feature),
        };
    }
    // While this tool runs on a cancellation worker thread, the message loop owns
    // the transport reader; a worker must not also read it (two readers on one
    // serial stream would race/deadlock). Fall back gracefully — apply-gated tools
    // still enforce their apply=true gate without the interactive round trip.
    if (server.worker_active.load(.acquire)) {
        return .{
            .supported = true,
            .used = false,
            .status = .unsupported,
            .unavailable_reason = "client protocol requests are unavailable while this tool runs as a cancellable background task",
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

    // Honor a deadline so a silent or non-matching-frame-streaming client cannot
    // wedge/live-lock the serial server (MEDIUM-2). `timeout_ms` is the caller's
    // value or a sane default; the deadline is checked before each receive so a
    // client that keeps sending non-matching frames still terminates the wait.
    // (A client that blocks the read syscall indefinitely cannot be preempted by
    // a userspace check; the deadline bounds the live-lock case.)
    const timeout_ms = request.timeout_ms orelse default_timeout_ms;
    const start_ms = nowMs(io);
    const deadline_ms = start_ms +| timeout_ms;

    while (true) {
        if (nowMs(io) >= deadline_ms) return .{
            .supported = true,
            .used = false,
            .status = .timeout,
            .unavailable_reason = "client protocol response was not received before the configured timeout",
        };
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

/// Refuses an inbound request that arrives while we are blocked awaiting a
/// client protocol reply; re-entrant dispatch on the serial transport is unsafe.
fn rejectNestedRequest(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
        .roots => supportsRoots(server),
    };
}

fn classifyProtocolResponse(feature: app_ports.ProtocolFeature, response: ?std.json.Value) ResponseStatus {
    return switch (feature) {
        .elicitation => classifyElicitationResponse(response),
        .sampling => classifySamplingResponse(response),
        .roots => classifyRootsResponse(response),
    };
}

fn protocolStatus(status: ResponseStatus) app_ports.ProtocolResponseStatus {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
        .roots => "client did not advertise MCP roots support",
    };
}

fn unavailableReason(status: ResponseStatus) []const u8 {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return switch (status) {
        .accepted => "",
        .declined => "client declined the protocol helper request",
        .cancelled => "client cancelled the protocol helper request",
        .malformed => "client protocol helper response had an unsupported shape",
        .timeout => "client protocol helper response was not available",
    };
}

/// Current wall-clock milliseconds as an unsigned saturating value for deadline
/// comparison. Negative/garbage clock values clamp to 0.
fn nowMs(io: std.Io) u64 {
    const ns = std.Io.Clock.now(.real, io).nanoseconds;
    const ms = @divTrunc(ns, std.time.ns_per_ms);
    return std.math.cast(u64, ms) orelse 0;
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
    // Keep this logic centralized so callers observe one consistent behavior path.
    var obj: std.json.ObjectMap = .empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = "protocol_helper_fallback" });
    try obj.put(allocator, "feature", .{ .string = feature });
    try obj.put(allocator, "method", .{ .string = method });
    try obj.put(allocator, "supported", .{ .bool = false });
    try obj.put(allocator, "resolution", .{ .string = "Client did not advertise this optional MCP capability; continue with deterministic zigars arguments and structured tool results." });
    return .{ .object = obj };
}

/// Sends one server→client request and returns a descriptor of it (feature,
/// method, outbound `request_id`) without awaiting the reply. The id is recorded
/// in `pending_requests` so a later response is recognized by the main loop.
fn sendClientRequestValue(server: anytype, io: std.Io, allocator: std.mem.Allocator, feature: []const u8, method: []const u8, params: std.json.Value) !std.json.Value {
    // Keep this logic centralized so callers observe one consistent behavior path.
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
