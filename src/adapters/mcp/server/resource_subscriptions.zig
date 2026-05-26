//! Minimal resource subscribe/unsubscribe handlers gated by advertised capabilities.
const std = @import("std");
const mcp = @import("mcp");

const jsonrpc = mcp.jsonrpc;

/// Acknowledges resources/subscribe when the server advertises support.
pub fn handleSubscribe(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    if (!supported(server)) return server.sendInvalidParams(io, allocator, request.id, "Resource subscriptions are not supported by this server");
    try sendEmpty(server, io, allocator, request.id);
}

/// Acknowledges resources/unsubscribe when the server advertises support.
pub fn handleUnsubscribe(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    if (!supported(server)) return server.sendInvalidParams(io, allocator, request.id, "Resource subscriptions are not supported by this server");
    try sendEmpty(server, io, allocator, request.id);
}

/// Checks the negotiated resource subscription capability flag.
fn supported(server: anytype) bool {
    return if (server.capabilities.resources) |resources_cap| resources_cap.subscribe else false;
}

/// Sends the empty JSON object response required for subscription ack.
fn sendEmpty(server: anytype, io: std.Io, allocator: std.mem.Allocator, id: mcp.types.RequestId) !void {
    var result: std.json.ObjectMap = .empty;
    defer result.deinit(allocator);
    try server.sendResponse(io, allocator, .{ .response = jsonrpc.createResponse(id, .{ .object = result }) });
}
