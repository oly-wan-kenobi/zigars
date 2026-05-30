//! Pins the structured resource error contract: every resource error value
//! must carry stable fields (kind, ok, uri, resource, phase, error, error_kind)
//! so callers can distinguish not_found and other failure classifications.

const std = @import("std");

const resource_errors = @import("../../../../adapters/mcp/resource_errors.zig");

test "resource error value includes stable contract fields" {
    const err_value = try resource_errors.valueFromError(std.testing.allocator, .{
        .uri = "zigars://workspace/import-graph",
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
    try std.testing.expectEqualStrings("zigars://workspace/import-graph", obj.get("uri").?.string);
    try std.testing.expectEqualStrings("workspace_import_graph", obj.get("resource").?.string);
    try std.testing.expectEqualStrings("scan_import_graph", obj.get("phase").?.string);
    try std.testing.expectEqualStrings("FileNotFound", obj.get("error").?.string);
    try std.testing.expectEqualStrings("not_found", obj.get("error_kind").?.string);
}
