//! Structured error payloads for MCP resource operations and dynamic URI handling.
const std = @import("std");
const mcp = @import("mcp");

const tool_errors = @import("errors.zig");

/// Additional JSON fields copied into a resource error object.
pub const Detail = struct {
    key: []const u8,
    value: std.json.Value,
};

/// Stable resource error envelope fields, scoped by URI and resource name.
pub const Spec = struct {
    kind: []const u8 = "resource_error",
    uri: []const u8,
    resource: []const u8,
    operation: []const u8,
    phase: []const u8,
    code: []const u8,
    category: []const u8,
    retryable: bool = false,
    resolution: []const u8,
    details: []const Detail = &.{},
};

/// Produces a JSON error object owned by `allocator` for embedding in responses.
pub fn value(allocator: std.mem.Allocator, spec: Spec) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    try obj.put(allocator, "kind", .{ .string = spec.kind });
    try obj.put(allocator, "ok", .{ .bool = false });
    try obj.put(allocator, "uri", .{ .string = spec.uri });
    try obj.put(allocator, "resource", .{ .string = spec.resource });
    try obj.put(allocator, "operation", .{ .string = spec.operation });
    try obj.put(allocator, "phase", .{ .string = spec.phase });
    try obj.put(allocator, "code", .{ .string = spec.code });
    try obj.put(allocator, "category", .{ .string = spec.category });
    try obj.put(allocator, "retryable", .{ .bool = spec.retryable });
    try obj.put(allocator, "resolution", .{ .string = spec.resolution });
    for (spec.details) |detail| try obj.put(allocator, detail.key, detail.value);
    return .{ .object = obj };
}

/// Extends `value` with normalized error name and error_kind fields.
pub fn valueFromError(allocator: std.mem.Allocator, spec: Spec, err: anyerror) !std.json.Value {
    var result_value = try value(allocator, spec);
    try result_value.object.put(allocator, "error", .{ .string = @errorName(err) });
    try result_value.object.put(allocator, "error_kind", .{ .string = tool_errors.kindForError(err) });
    return result_value;
}

/// Serializes a JSON value into owned application/json resource text.
pub fn jsonContent(allocator: std.mem.Allocator, uri: []const u8, result_value: std.json.Value) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    var aw_owned = true;
    defer if (aw_owned) aw.deinit();
    std.json.Stringify.value(result_value, .{ .whitespace = .indent_2 }, &aw.writer) catch return error.OutOfMemory;
    const text = aw.toOwnedSlice() catch return error.OutOfMemory;
    aw_owned = false;
    return .{ .uri = uri, .mimeType = "application/json", .text = text };
}

/// Builds and serializes a resource error unless the original failure was OOM.
pub fn jsonContentFromError(allocator: std.mem.Allocator, spec: Spec, err: anyerror) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    var result_value = valueFromError(allocator, spec, err) catch return error.OutOfMemory;
    defer deinitTopLevel(allocator, &result_value);
    return jsonContent(allocator, spec.uri, result_value);
}

fn deinitTopLevel(allocator: std.mem.Allocator, result_value: *std.json.Value) void {
    switch (result_value.*) {
        .object => |*obj| obj.deinit(allocator),
        else => {},
    }
}
