const std = @import("std");
const mcp = @import("mcp");

const jsonrpc = mcp.jsonrpc;

pub fn handleSubscribe(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    if (!supported(server)) return server.sendInvalidParams(io, allocator, request.id, "Resource subscriptions are not supported by this server");
    try sendEmpty(server, io, allocator, request.id);
}

pub fn handleUnsubscribe(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: jsonrpc.Request) !void {
    if (!supported(server)) return server.sendInvalidParams(io, allocator, request.id, "Resource subscriptions are not supported by this server");
    try sendEmpty(server, io, allocator, request.id);
}

fn supported(server: anytype) bool {
    return if (server.capabilities.resources) |resources_cap| resources_cap.subscribe else false;
}

fn sendEmpty(server: anytype, io: std.Io, allocator: std.mem.Allocator, id: mcp.types.RequestId) !void {
    var result: std.json.ObjectMap = .empty;
    defer result.deinit(allocator);
    try server.sendResponse(io, allocator, .{ .response = jsonrpc.createResponse(id, .{ .object = result }) });
}
