const std = @import("std");

const mcp_result = @import("../../../../../adapters/mcp/result.zig");
const result_contracts = @import("../../../../../app/result_contracts.zig");
const result_shape = @import("../../../../../adapters/mcp/tools/result_shape.zig");

test "output budget adapter preserves public field names" {
    const allocator = std.testing.allocator;
    var args = std.json.ObjectMap.empty;
    defer args.deinit(allocator);
    try args.put(allocator, "mode", .{ .string = "compact" });
    try args.put(allocator, "token_budget", .{ .integer = 100 });
    try args.put(allocator, "tool", .{ .string = "zig_check" });

    const result = try result_shape.zigarOutputBudgetPlan(allocator, .{ .object = args });
    defer mcp_result.deinitToolResult(allocator, result);

    try std.testing.expect(!result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigar_output_budget_plan", obj.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, result_contracts.min_token_budget), obj.get("effective_token_budget").?.integer);
    try std.testing.expectEqualStrings("zig_check", obj.get("tool").?.string);
}

test "result shape adapters reject invalid modes with structured errors" {
    const allocator = std.testing.allocator;
    var args = std.json.ObjectMap.empty;
    defer args.deinit(allocator);
    try args.put(allocator, "mode", .{ .string = "verbose" });

    const shape = try result_shape.zigarResultShape(allocator, .{ .object = args });
    defer mcp_result.deinitToolResult(allocator, shape);
    try std.testing.expect(shape.is_error);
    try std.testing.expectEqualStrings("invalid_argument", shape.structuredContent.?.object.get("code").?.string);

    const budget = try result_shape.zigarOutputBudgetPlan(allocator, .{ .object = args });
    defer mcp_result.deinitToolResult(allocator, budget);
    try std.testing.expect(budget.is_error);
    try std.testing.expectEqualStrings("invalid_argument", budget.structuredContent.?.object.get("code").?.string);
}
