const std = @import("std");
const zigar = @import("zigar");

const agent = @import("agent.zig");
const agent_values = @import("agent_values.zig");
const common = @import("common.zig");

const App = common.App;

fn testAgentApp(allocator: std.mem.Allocator) !App {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .config = .{ .workspace = ".", .zig_path = "zig" },
        .workspace = try zigar.workspace.Workspace.init(allocator, std.testing.io, ".", null),
    };
}

test "agent workflow values expose evidence and limitations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const next = try agent_values.nextActionPlanValue(allocator, "fix compile error", "src/main.zig", "error: bad");
    const next_obj = next.object;
    try std.testing.expectEqualStrings("keyword match over user goal, optional changed_files, and optional last_error", next_obj.get("classification_reasons").?.string);
    const next_contract = next_obj.get("workflow_contract").?.object;
    try std.testing.expectEqualStrings("medium", next_contract.get("confidence").?.string);
    try std.testing.expect(std.mem.indexOf(u8, next_contract.get("limitations").?.string, "keyword classification") != null);

    var app = try testAgentApp(allocator);
    const impact = try agent_values.impactValue(allocator, &app, "src/main.zig", "main", 10);
    const impact_obj = impact.object;
    try std.testing.expectEqualStrings("heuristic text/import scan; not semantic dependency proof", impact_obj.get("limitations").?.string);
    try std.testing.expectEqualStrings("zigar_validate_patch", impact_obj.get("workflow_contract").?.object.get("verification").?.string);
}

test "validate patch exposes skipped phase reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testAgentApp(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "mode", .{ .string = "quick" });
    try args.put(allocator, "changed_files", .{ .string = "README.md" });
    const result = try agent.zigarValidatePatch(&app, allocator, .{ .object = args });
    const obj = result.structuredContent.?.object;
    try std.testing.expectEqual(@as(usize, 1), obj.get("skipped_phases").?.array.items.len);
    try std.testing.expectEqualStrings("build_test", obj.get("skipped_phases").?.array.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("medium", obj.get("workflow_contract").?.object.get("confidence").?.string);
}
