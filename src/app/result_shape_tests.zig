//! Pins the JSON result-shape builders that adapters serialize: mode parsing,
//! the materialized contract object exposing stable fields and per-mode omission
//! lists, and budget plans clamping requested budgets while allocating priority
//! order by mode. Uses an arena so allocator-owned JSON values free in bulk.
const std = @import("std");

const result_shape = @import("result_shape.zig");

test "parses supported result shape modes" {
    try std.testing.expectEqual(result_shape.ResultShapeMode.compact, result_shape.parseMode("compact").?);
    try std.testing.expectEqual(result_shape.ResultShapeMode.standard, result_shape.parseMode("standard").?);
    try std.testing.expectEqual(result_shape.ResultShapeMode.deep, result_shape.parseMode("deep").?);
    try std.testing.expect(result_shape.parseMode("verbose") == null);
}

test "result shape contract exposes stable fields and omissions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const value = try result_shape.contractValue(allocator, .compact);
    const obj = value.object;
    try std.testing.expectEqualStrings("zigars_result_shape", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("compact", obj.get("selected_mode").?.string);
    try std.testing.expectEqual(@as(usize, 3), obj.get("supported_modes").?.array.items.len);
    const selected = obj.get("selected_mode_metadata").?.object;
    try std.testing.expectEqualStrings("compact", selected.get("mode").?.string);
    try std.testing.expectEqualStrings("raw_backend_output", selected.get("omitted_by_default").?.array.items[0].string);
}

test "budget plans clamp requested budgets and allocate by mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const low = (try result_shape.budgetPlanValue(allocator, .{ .mode = .compact, .requested_token_budget = 12, .tool_name = "zig_check" })).object;
    try std.testing.expectEqual(@as(i64, result_shape.min_token_budget), low.get("effective_token_budget").?.integer);
    try std.testing.expect(low.get("clamp_applied").?.bool);
    try std.testing.expectEqualStrings("zig_check", low.get("tool").?.string);

    const deep = (try result_shape.budgetPlanValue(allocator, .{ .mode = .deep })).object;
    try std.testing.expectEqual(@as(i64, result_shape.ResultShapeMode.deep.defaultBudget()), deep.get("effective_token_budget").?.integer);
    try std.testing.expect(!deep.get("clamp_applied").?.bool);
    try std.testing.expectEqualStrings("expanded_evidence", deep.get("allocation").?.object.get("priority_order").?.array.items[1].string);
}
