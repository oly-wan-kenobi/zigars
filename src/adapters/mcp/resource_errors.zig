const std = @import("std");
const mcp = @import("mcp");

const tool_errors = @import("errors.zig");

pub const Detail = struct {
    key: []const u8,
    value: std.json.Value,
};

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

pub fn valueFromError(allocator: std.mem.Allocator, spec: Spec, err: anyerror) !std.json.Value {
    var result_value = try value(allocator, spec);
    try result_value.object.put(allocator, "error", .{ .string = @errorName(err) });
    try result_value.object.put(allocator, "error_kind", .{ .string = tool_errors.kindForError(err) });
    return result_value;
}

pub fn jsonContent(allocator: std.mem.Allocator, uri: []const u8, result_value: std.json.Value) mcp.resources.ResourceError!mcp.resources.ResourceContent {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    std.json.Stringify.value(result_value, .{ .whitespace = .indent_2 }, &aw.writer) catch return error.OutOfMemory;
    return .{ .uri = uri, .mimeType = "application/json", .text = aw.toOwnedSlice() catch return error.OutOfMemory };
}

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

test "resource error value includes stable contract fields" {
    const err_value = try valueFromError(std.testing.allocator, .{
        .uri = "zigar://workspace/import-graph",
        .resource = "workspace_import_graph",
        .operation = "read_resource",
        .phase = "scan_import_graph",
        .code = "import_graph_failed",
        .category = "analysis",
        .resolution = "retry after checking the workspace",
    }, error.FileNotFound);
    var value_copy = err_value;
    defer value_copy.object.deinit(std.testing.allocator);

    const obj = err_value.object;
    try std.testing.expectEqualStrings("resource_error", obj.get("kind").?.string);
    try std.testing.expect(!obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("zigar://workspace/import-graph", obj.get("uri").?.string);
    try std.testing.expectEqualStrings("workspace_import_graph", obj.get("resource").?.string);
    try std.testing.expectEqualStrings("scan_import_graph", obj.get("phase").?.string);
    try std.testing.expectEqualStrings("FileNotFound", obj.get("error").?.string);
    try std.testing.expectEqualStrings("not_found", obj.get("error_kind").?.string);
}
