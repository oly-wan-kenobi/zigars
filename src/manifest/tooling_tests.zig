const std = @import("std");
const subject = @import("tooling.zig");
const catalog_json = subject.catalog_json;
const SchemaField = subject.SchemaField;
const SchemaFieldHint = subject.SchemaFieldHint;
const SchemaSpec = subject.SchemaSpec;
const FieldHint = subject.FieldHint;
const schema = subject.schema;
const schemaWithHints = subject.schemaWithHints;
const hintFor = subject.hintFor;
const boolDefault = subject.boolDefault;
const intDefault = subject.intDefault;

test "static catalog declares generated manifest sections" {
    try std.testing.expect(std.mem.indexOf(u8, catalog_json, "\"tool_argument_scope\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_json, "\"tools_list_schema_note\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog_json, "\"source_write_gate\"") != null);
}
test "field hints expose reusable runtime defaults" {
    const spec = schema(&.{
        .{ "probe_managers", "boolean", false },
        .{ "stop_on_failure", "boolean", false },
        .{ "wait_ms", "integer", false },
    });
    try std.testing.expect(!boolDefault(spec, "probe_managers", true));
    try std.testing.expect(!boolDefault(spec, "stop_on_failure", true));
    try std.testing.expect(boolDefault(spec, "unknown", true));
    try std.testing.expectEqual(@as(i64, 500), intDefault(spec, "wait_ms", 0));
    try std.testing.expectEqual(@as(i64, 42), intDefault(spec, "unknown", 42));
}
test "field hints can be scoped to one schema" {
    const context = schemaWithHints(&.{.{ "mode", "string", false }}, &.{
        .{ .field_name = "mode", .hint = .{ .description = "Context-pack depth.", .enum_values = &.{ "tiny", "standard", "deep" } } },
    });
    const validate = schemaWithHints(&.{.{ "mode", "string", false }}, &.{
        .{ .field_name = "mode", .hint = .{ .description = "Validation depth.", .enum_values = &.{ "quick", "standard", "full" } } },
    });

    try std.testing.expect(containsString(hintFor(context, context.fields[0]).enum_values, "deep"));
    try std.testing.expect(!containsString(hintFor(context, context.fields[0]).enum_values, "quick"));
    try std.testing.expect(containsString(hintFor(validate, validate.fields[0]).enum_values, "quick"));
    try std.testing.expect(!containsString(hintFor(validate, validate.fields[0]).enum_values, "deep"));
}

/// Returns whether a string slice set contains the expected value.
fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}
