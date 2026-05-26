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
    try std.testing.expectEqualStrings("input_file", file.get("x-zigar-path-kind").?.string);
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

/// Releases allocated JSON schema values built for tests.
fn deinitInputSchema(s: *mcp.types.InputSchema) void {
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
