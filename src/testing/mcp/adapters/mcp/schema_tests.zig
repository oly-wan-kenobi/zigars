//! Pins the MCP JSON schema projection contract: input schemas must include
//! discovery hints and path annotations, enum schemas must emit enum arrays,
//! and output schemas must project the standard envelope shape with required
//! fields and a JSON Schema dialect marker.

const std = @import("std");
const mcp = @import("mcp");

const schema = @import("../../../../adapters/mcp/schema.zig");
const tooling = @import("../../../../manifest/tooling.zig");

test "input schema includes discovery hints" {
    var s = try schema.buildInputSchema(std.testing.allocator, tooling.schema(&.{
        .{ "file", "string", true },
        .{ "apply", "boolean", false },
    }));
    defer deinitInputSchema(&s);
    const file = s.properties.?.object.get("file").?.object;
    try std.testing.expectEqualStrings("Workspace-relative source file path.", file.get("description").?.string);
    try std.testing.expectEqualStrings("input_file", file.get("x-zigars-path-kind").?.string);
    const apply = s.properties.?.object.get("apply").?.object;
    try std.testing.expect(!apply.get("default").?.bool);
}

test "input schema includes enum hints" {
    var s = try schema.buildInputSchema(std.testing.allocator, tooling.schemaWithHints(&.{
        .{ "mode", "string", false },
    }, &.{
        .{ .field_name = "mode", .hint = .{ .description = "Mode.", .enum_values = &.{ "quick", "full" } } },
    }));
    defer deinitInputSchema(&s);
    const mode = s.properties.?.object.get("mode").?.object;
    try std.testing.expectEqual(@as(usize, 2), mode.get("enum").?.array.items.len);
    try std.testing.expectEqualStrings("quick", mode.get("enum").?.array.items[0].string);
}

test "output schema projects shared envelope shapes" {
    var s = try schema.buildOutputSchema(std.testing.allocator, tooling.outputSchema(.artifact));
    defer deinitOutputSchema(&s);
    try std.testing.expectEqualStrings("https://json-schema.org/draft/2020-12/schema", s.@"$schema".?);
    const props = s.properties.?.object;
    try std.testing.expectEqualStrings("object", s.type);
    try std.testing.expect(props.get("kind") != null);
    try std.testing.expect(props.get("resource_uri") != null);
    try std.testing.expectEqualStrings("kind", s.required.?[0]);
}

/// Releases allocated JSON schema values built for tests.
fn deinitInputSchema(s: *mcp.types.InputSchema) void {
    // Only release owned state here to avoid invalidating borrowed data.
    if (s.required) |required| std.testing.allocator.free(required);
    if (s.properties) |*properties| {
        var it = properties.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.object.get("enum")) |*value| value.array.deinit();
            entry.value_ptr.object.deinit(std.testing.allocator);
        }
        properties.object.deinit(std.testing.allocator);
    }
}

/// Releases allocated JSON output schema values built for tests.
fn deinitOutputSchema(s: *mcp.types.OutputSchema) void {
    if (s.required) |required| std.testing.allocator.free(required);
    if (s.properties) |*properties| {
        var it = properties.object.iterator();
        while (it.next()) |entry| entry.value_ptr.object.deinit(std.testing.allocator);
        properties.object.deinit(std.testing.allocator);
    }
}
