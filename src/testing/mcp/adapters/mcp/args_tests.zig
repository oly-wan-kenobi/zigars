const std = @import("std");

const args = @import("../../../../adapters/mcp/args.zig");
const manifest = @import("../../../../manifest/mod.zig");
const tooling = @import("../../../../manifest/tooling.zig");

test "finds schema fields" {
    const spec = manifest.find("zig_check").?;
    const field = args.findSchemaField(spec.input_schema, "file").?;
    try std.testing.expect(field[2]);
    try std.testing.expectEqualStrings("string", field[1]);
}

test "accepts empty argument object for no-argument tool" {
    const spec = manifest.find("zig_version").?;
    var obj = std.json.ObjectMap.empty;
    defer obj.deinit(std.testing.allocator);
    const result = try args.validateToolArgs(std.testing.allocator, spec, .{ .object = obj });
    try std.testing.expect(result == null);
}

test "accepts absent params for tools without required arguments" {
    const spec = manifest.find("zig_version").?;
    try std.testing.expect((try args.validateToolArgs(std.testing.allocator, spec, null)) == null);
}

test "rejects missing required argument when params are absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const spec = manifest.find("zig_check").?;

    const result = (try args.validateToolArgs(arena.allocator(), spec, null)).?;
    const err = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("missing_required_argument", err.get("code").?.string);
    try std.testing.expectEqualStrings("file", err.get("field").?.string);
}

test "rejects enum arguments outside schema hints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spec = manifest.find("zigar_context_pack").?;

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "mode", .{ .string = "sideways" });
    const result = (try args.validateToolArgs(allocator, spec, .{ .object = obj })).?;
    const err = result.structuredContent.?.object;

    try std.testing.expectEqualStrings("argument_error", err.get("kind").?.string);
    try std.testing.expectEqualStrings("invalid_enum_value", err.get("code").?.string);
    try std.testing.expectEqualStrings("mode", err.get("field").?.string);
    try std.testing.expect(std.mem.indexOf(u8, err.get("expected").?.string, "standard") != null);
    try std.testing.expectEqualStrings("sideways", err.get("actual").?.string);
}

test "validates enum hints in tool context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const context_spec = manifest.find("zigar_context_pack").?;
    const validate_spec = manifest.find("zigar_validate_patch").?;

    var context_obj = std.json.ObjectMap.empty;
    try context_obj.put(allocator, "mode", .{ .string = "quick" });
    const context_result = (try args.validateToolArgs(allocator, context_spec, .{ .object = context_obj })).?;
    const context_err = context_result.structuredContent.?.object;
    try std.testing.expectEqualStrings("invalid_enum_value", context_err.get("code").?.string);
    try std.testing.expect(std.mem.indexOf(u8, context_err.get("expected").?.string, "deep") != null);
    try std.testing.expect(std.mem.indexOf(u8, context_err.get("expected").?.string, "quick") == null);

    var validate_obj = std.json.ObjectMap.empty;
    try validate_obj.put(allocator, "mode", .{ .string = "quick" });
    try std.testing.expect((try args.validateToolArgs(allocator, validate_spec, .{ .object = validate_obj })) == null);

    var invalid_validate_obj = std.json.ObjectMap.empty;
    try invalid_validate_obj.put(allocator, "mode", .{ .string = "deep" });
    const validate_result = (try args.validateToolArgs(allocator, validate_spec, .{ .object = invalid_validate_obj })).?;
    const validate_err = validate_result.structuredContent.?.object;
    try std.testing.expectEqualStrings("invalid_enum_value", validate_err.get("code").?.string);
    try std.testing.expect(std.mem.indexOf(u8, validate_err.get("expected").?.string, "quick") != null);
    try std.testing.expect(std.mem.indexOf(u8, validate_err.get("expected").?.string, "deep") == null);
}

test "rejects integer arguments below schema minimum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const spec = manifest.find("zig_std_search").?;

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "query", .{ .string = "ArrayList" });
    try obj.put(allocator, "limit", .{ .integer = 0 });
    const result = (try args.validateToolArgs(allocator, spec, .{ .object = obj })).?;
    const err = result.structuredContent.?.object;

    try std.testing.expectEqualStrings("argument_error", err.get("kind").?.string);
    try std.testing.expectEqualStrings("below_minimum", err.get("code").?.string);
    try std.testing.expectEqualStrings("limit", err.get("field").?.string);
    try std.testing.expectEqualStrings("integer >= 1", err.get("expected").?.string);
    try std.testing.expectEqualStrings("0", err.get("actual").?.string);
}

test "rejects integer arguments above schema maximum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const base = manifest.find("zig_check").?;
    const spec = manifest.ToolMeta{
        .id = base.id,
        .name = "bounded_tool",
        .description = "bounded fixture",
        .input_schema = tooling.schemaWithHints(&.{.{ "count", "integer", true }}, &.{
            .{ .field_name = "count", .hint = .{ .description = "Bounded count.", .minimum = 1, .maximum = 3 } },
        }),
        .output_schema = null,
        .read_only = true,
    };

    var obj = std.json.ObjectMap.empty;
    try obj.put(allocator, "count", .{ .integer = 4 });
    const result = (try args.validateToolArgs(allocator, spec, .{ .object = obj })).?;
    const err = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("above_maximum", err.get("code").?.string);
    try std.testing.expectEqualStrings("integer <= 3", err.get("expected").?.string);
    try std.testing.expectEqualStrings("4", err.get("actual").?.string);
}
