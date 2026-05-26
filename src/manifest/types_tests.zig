const std = @import("std");
const subject = @import("types.zig");
const tooling = subject.tooling;
const ToolGroup = subject.ToolGroup;
const StaticAnalysisTier = subject.StaticAnalysisTier;
const ToolRisk = subject.ToolRisk;
const FileCommandPlan = subject.FileCommandPlan;
const CommandPlan = subject.CommandPlan;
const ZlsPlan = subject.ZlsPlan;
const PlanPolicy = subject.PlanPolicy;
const ToolDefinition = subject.ToolDefinition;
const GroupSpec = subject.GroupSpec;
const schema = subject.schema;
const schemaWithHints = subject.schemaWithHints;
const fieldHint = subject.fieldHint;
const tool = subject.tool;

test "manifest type helpers preserve schema hints and tool metadata" {
    const spec = schemaWithHints(&.{.{ "file", "string", true }}, &.{fieldHint("file", .{ .description = "Fixture file.", .path_kind = "input_file" })});
    try std.testing.expectEqual(@as(usize, 1), spec.fields.len);
    try std.testing.expectEqual(@as(usize, 1), spec.field_hints.len);
    const definition = tool(.{
        .description = "fixture",
        .input_schema = spec,
        .group = .core_zig,
        .plan = .{ .pure_analysis = "fixture" },
    });
    try std.testing.expect(definition.read_only);
    try std.testing.expectEqual(ToolGroup.core_zig, definition.group);
}
