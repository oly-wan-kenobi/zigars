//! Tests for the project_intelligence MCP tool adapter.
//! Pins the contract that changed_files argument parsing produces a
//! ValidationRunRequest with the expected changed_paths slice.

const std = @import("std");

const project_intelligence = @import("../../../../../adapters/mcp/tools/project_intelligence.zig");

test "project intelligence adapter parses validation run requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "changed_files", .{ .string = "src/main.zig" });
    var parsed = try project_intelligence.validationRunRequestFromArgs(allocator, .{ .object = args }, 10_000);
    defer parsed.deinit(allocator);
    try std.testing.expectEqualStrings("src/main.zig", parsed.request.plan.changed_paths[0]);
}
