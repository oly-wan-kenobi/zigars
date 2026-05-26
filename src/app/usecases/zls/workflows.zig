//! ZLS workflow helpers for document sync and workspace lifecycle operations.
const std = @import("std");

const app_context = @import("../../context.zig");

/// Serializes document sync fields into an allocator-owned JSON value; allocation failures propagate.
pub fn documentSyncValue(allocator: std.mem.Allocator, context: app_context.ZlsContext, tool_name: []const u8, file: []const u8, content: []const u8) !std.json.Value {
    const sync = try context.zls_gateway.sync(allocator, .{ .file = file, .content = content, .provenance = tool_name });
    defer sync.deinit(allocator);
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "uri", try ownedString(allocator, sync.uri));
    try obj.put(allocator, "version", .{ .integer = 0 });
    try obj.put(allocator, "open", .{ .bool = true });
    obj_owned = false;
    return .{ .object = obj };
}

/// Serializes document status fields into an allocator-owned JSON value; allocation failures propagate.
pub fn documentStatusValue(allocator: std.mem.Allocator, context: app_context.Context, file: []const u8) !std.json.Value {
    const workspace_store = try context.requireWorkspace();
    const resolved = try workspace_store.resolve(allocator, .{ .path = file, .provenance = "zls.document_status" });
    defer resolved.deinit(allocator);
    var obj = std.json.ObjectMap.empty;
    var obj_owned = true;
    defer if (obj_owned) obj.deinit(allocator);
    try obj.put(allocator, "file", try ownedString(allocator, file));
    try obj.put(allocator, "uri", try uriValue(allocator, resolved.path));
    try obj.put(allocator, "open", .{ .bool = context.zls_state.running });
    obj_owned = false;
    return .{ .object = obj };
}

/// Copies the provided string into allocator-owned storage.
fn ownedString(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return .{ .string = try allocator.dupe(u8, text) };
}

/// Serializes uri fields into an allocator-owned JSON value; allocation failures propagate.
fn uriValue(allocator: std.mem.Allocator, path: []const u8) !std.json.Value {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(allocator, "file://");
    try out.appendSlice(allocator, path);
    return .{ .string = try out.toOwnedSlice(allocator) };
}
