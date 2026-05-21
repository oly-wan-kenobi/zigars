const std = @import("std");
const zigar = @import("zigar");

const common = @import("common.zig");
const result_shape = zigar.result_shape;
const result_shape_tools = @import("result_shape.zig");

const App = common.App;

fn testApp(allocator: std.mem.Allocator) !App {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .config = .{ .workspace = ".", .zig_path = "zig" },
        .workspace = try zigar.workspace.Workspace.init(allocator, std.testing.io, ".", null),
    };
}

test "zigar_result_shape handler returns selected mode contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testApp(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "mode", .{ .string = "deep" });
    const result = try result_shape_tools.zigarResultShape(&app, allocator, .{ .object = args });
    defer zigar.json_result.deinitToolResult(allocator, result);

    try std.testing.expect(!result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigar_result_shape", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("deep", obj.get("selected_mode").?.string);
    try std.testing.expectEqual(@as(usize, 3), obj.get("supported_modes").?.array.items.len);
}

test "zigar_result_shape handler rejects unsupported mode with structured argument error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testApp(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "mode", .{ .string = "verbose" });
    const result = try result_shape_tools.zigarResultShape(&app, allocator, .{ .object = args });
    defer zigar.json_result.deinitToolResult(allocator, result);

    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("argument_error", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("mode", obj.get("field").?.string);
    try std.testing.expectEqualStrings("verbose", obj.get("actual").?.string);
}

test "zigar_output_budget_plan handler returns clamped budget plan" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testApp(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "mode", .{ .string = "compact" });
    try args.put(allocator, "token_budget", .{ .integer = 100 });
    try args.put(allocator, "tool", .{ .string = "zig_check" });
    const result = try result_shape_tools.zigarOutputBudgetPlan(&app, allocator, .{ .object = args });
    defer zigar.json_result.deinitToolResult(allocator, result);

    try std.testing.expect(!result.is_error);
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqualStrings("zigar_output_budget_plan", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("compact", obj.get("mode").?.string);
    try std.testing.expectEqual(@as(i64, result_shape.min_token_budget), obj.get("effective_token_budget").?.integer);
    try std.testing.expect(obj.get("clamp_applied").?.bool);
    try std.testing.expectEqualStrings("zig_check", obj.get("tool").?.string);
}
