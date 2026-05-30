//! Pins the structured tool error contract: every tool error value must
//! carry stable fields (kind, ok, tool, operation, phase, code, category)
//! and must be surfaced as an MCP is_error result with structuredContent.

const std = @import("std");

const errors = @import("../../../../adapters/mcp/errors.zig");
const mcp_result = @import("../../../../adapters/mcp/result.zig");

test "tool error value includes stable contract fields" {
    const err_value = try errors.value(std.testing.allocator, .{
        .tool = "zig_format",
        .operation = "format_preview",
        .phase = "read_source",
        .code = "read_failed",
        .category = "filesystem",
        .resolution = "retry with a readable workspace file",
        .details = &.{.{ .key = "file", .value = .{ .string = "src/main.zig" } }},
    });
    var value_copy = err_value;
    defer value_copy.object.deinit(std.testing.allocator);

    const obj = err_value.object;
    try std.testing.expectEqualStrings("tool_error", obj.get("kind").?.string);
    try std.testing.expect(!obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("zig_format", obj.get("tool").?.string);
    try std.testing.expectEqualStrings("format_preview", obj.get("operation").?.string);
    try std.testing.expectEqualStrings("read_source", obj.get("phase").?.string);
    try std.testing.expectEqualStrings("read_failed", obj.get("code").?.string);
    try std.testing.expectEqualStrings("filesystem", obj.get("category").?.string);
    try std.testing.expectEqualStrings("src/main.zig", obj.get("file").?.string);
}

test "tool error result is marked as an MCP error with structured content" {
    const allocator = std.testing.allocator;
    const tool_result = try errors.missingArgument(allocator, "zig_format", "file", "string");
    defer mcp_result.deinitToolResult(allocator, tool_result);

    try std.testing.expect(tool_result.is_error);
    const obj = tool_result.structuredContent.?.object;
    try std.testing.expectEqualStrings("argument_error", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("zig_format", obj.get("tool").?.string);
    try std.testing.expectEqualStrings("file", obj.get("field").?.string);
}
