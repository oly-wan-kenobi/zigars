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

test "agent value helpers expose routing rules and validation decisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const rules = (try agent_values.agentRulesValue(allocator, "hermes", "profile a hot path")).array;
    try std.testing.expect(rules.items.len >= 7);
    try std.testing.expect(std.mem.indexOf(u8, rules.items[rules.items.len - 1].string, "zig_profile_plan") != null);

    const hints = (try agent_values.agentWorkflowHintsValue(allocator, "api review")).array;
    try std.testing.expect(hints.items.len >= 5);
    try std.testing.expectEqualStrings("api_change", hints.items[hints.items.len - 1].object.get("name").?.string);

    const aliases = (try agent_values.agentToolAliasesValue(allocator)).object;
    try std.testing.expectEqualStrings("zig_format", aliases.get("fmt").?.string);
    try std.testing.expectEqualStrings("zigar_validate_patch", aliases.get("done").?.string);

    const ready = (try agent_values.validationNextActionValue(allocator, true, std.json.Array.init(allocator))).object;
    try std.testing.expectEqualStrings("ready", ready.get("status").?.string);
    try std.testing.expect(ready.get("tool").? == .null);

    var failed_phases = std.json.Array.init(allocator);
    var failed_phase = std.json.ObjectMap.empty;
    try failed_phase.put(allocator, "name", .{ .string = "zig test" });
    try failed_phase.put(allocator, "ok", .{ .bool = false });
    try failed_phases.append(.{ .object = failed_phase });
    const blocked = (try agent_values.validationNextActionValue(allocator, false, failed_phases)).object;
    try std.testing.expectEqualStrings("blocked", blocked.get("status").?.string);
    try std.testing.expectEqualStrings("zigar_failure_fusion", blocked.get("tool").?.string);

    try std.testing.expect(agent_values.importsTarget("const m = @import(\"main.zig\");", "src/main.zig"));
    try std.testing.expect(agent_values.referencesFileStem("main.run();", "src/main.zig"));
    try std.testing.expect(agent_values.looksLikeTestFile("src/main_test.zig"));

    var public_api = std.json.Array.init(allocator);
    try agent_values.appendPublicDeclsForFile(allocator, &public_api, "src/lib.zig", "pub fn run() void {}\npub const Thing = struct {};\nconst hidden = 1;\n");
    try std.testing.expectEqual(@as(usize, 2), public_api.items.len);
    try std.testing.expectEqualStrings("run", public_api.items[0].object.get("name").?.string);
}

test "agent primary failure and profile helpers expose stable shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var primary = std.json.ObjectMap.empty;
    try primary.put(allocator, "message", .{ .string = "compile failed" });
    var summary = std.json.ObjectMap.empty;
    try summary.put(allocator, "primary", .{ .object = primary });
    var compiler = std.json.ObjectMap.empty;
    try compiler.put(allocator, "summary", .{ .object = summary });
    const compiler_primary = try agent_values.primaryFailureValue(allocator, .{ .object = compiler }, .null);
    try std.testing.expectEqualStrings("compile failed", compiler_primary.object.get("message").?.string);

    var failures = std.json.Array.init(allocator);
    var failure = std.json.ObjectMap.empty;
    try failure.put(allocator, "name", .{ .string = "test fails" });
    try failures.append(.{ .object = failure });
    var compiler_without_primary_summary = std.json.ObjectMap.empty;
    try compiler_without_primary_summary.put(allocator, "primary", .null);
    var compiler_without_primary = std.json.ObjectMap.empty;
    try compiler_without_primary.put(allocator, "summary", .{ .object = compiler_without_primary_summary });
    var tests = std.json.ObjectMap.empty;
    try tests.put(allocator, "failures", .{ .array = failures });
    const test_primary = try agent_values.primaryFailureValue(allocator, .{ .object = compiler_without_primary }, .{ .object = tests });
    try std.testing.expectEqualStrings("test fails", test_primary.object.get("name").?.string);

    const dirs = (try agent_values.generatedDirsValue(allocator)).array;
    try std.testing.expectEqualStrings(".zig-cache", dirs.items[0].string);

    var app = try testAgentApp(allocator);
    const profile = (try agent_values.generatedProjectProfileValue(allocator, &app)).object;
    try std.testing.expectEqual(@as(i64, 1), profile.get("schema_version").?.integer);
    try std.testing.expectEqualStrings("zigar_context_pack", profile.get("agent_entrypoint").?.string);
}
