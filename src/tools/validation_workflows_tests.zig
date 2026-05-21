const std = @import("std");
const zigar = @import("zigar");

const validation = @import("validation_workflows.zig");
const common = @import("common.zig");

const App = common.App;

fn testApp(allocator: std.mem.Allocator) !App {
    return .{
        .allocator = allocator,
        .io = std.testing.io,
        .config = .{ .workspace = ".", .zig_path = "zig" },
        .workspace = try zigar.workspace.Workspace.init(allocator, std.testing.io, ".", null),
    };
}

test "validation planner exposes explicit phases and skipped reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testApp(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "mode", .{ .string = "quick" });
    try args.put(allocator, "changed_files", .{ .string = "README.md" });
    const result = try validation.zigarValidationPlan(&app, allocator, .{ .object = args });
    const obj = result.structuredContent.?.object;

    try std.testing.expectEqualStrings("zigar_validation_plan", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("quick", obj.get("mode").?.string);
    try std.testing.expect(obj.get("skipped_phases").?.array.items.len >= 1);
    try std.testing.expectEqualStrings("plan-first; no environment installs or source writes are performed by this planner", obj.get("execution_policy").?.string);
}

test "event tools parse diagnostics and timing from captured text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testApp(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "text", .{ .string =
        \\src/main.zig:1:1: error: fixture failure
        \\1/1 test.foo...FAIL (TestExpectedEqual) 12ms
        \\
    });
    const result = try validation.zigTestEvents(&app, allocator, .{ .object = args });
    const obj = result.structuredContent.?.object;

    try std.testing.expectEqualStrings("zig_test_events", obj.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("compiler").?.object.get("error_count").?.integer);
    try std.testing.expect(obj.get("events").?.array.items.len >= 2);
    try std.testing.expect(obj.get("timings").?.array.items.len >= 1);
}

test "project memory reads supplied structured notes and built-in policies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testApp(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "content", .{ .string = "{\"category\":\"architecture\",\"title\":\"Use apply gates\",\"decision\":\"Writes need apply=true\"}\n" });
    try args.put(allocator, "query", .{ .string = "apply" });
    const result = try validation.zigarProjectMemory(&app, allocator, .{ .object = args });
    const obj = result.structuredContent.?.object;

    try std.testing.expectEqualStrings("zigar_project_memory", obj.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), obj.get("note_count").?.integer);
    try std.testing.expect(obj.get("built_in_project_policies").?.array.items.len >= 3);
}

test "semantic impact selects parser-backed tests from a fixture workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.zig", .data = "pub fn run() void {}\ntest \"run works\" {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "const lib = @import(\"lib.zig\");\npub fn main() void { lib.run(); }\n" });
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    const root_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    const root = root_z[0..];
    const ws = zigar.workspace.Workspace{ .allocator = allocator, .io = io, .root = root, .cache_root = root };
    var app = App{ .allocator = allocator, .io = io, .config = .{ .workspace = root, .zig_path = "zig" }, .workspace = ws };

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "files", .{ .string = "lib.zig" });
    try args.put(allocator, "symbols", .{ .string = "run" });
    try args.put(allocator, "limit", .{ .integer = 10 });
    const result = try validation.zigImpactSemantic(&app, allocator, .{ .object = args });
    const obj = result.structuredContent.?.object;

    try std.testing.expectEqualStrings("zig_impact_semantic", obj.get("kind").?.string);
    try std.testing.expect(obj.get("affected_importers").?.array.items.len >= 1);
    try std.testing.expect(obj.get("affected_tests").?.array.items.len >= 1);
    try std.testing.expectEqualStrings("parser_backed", obj.get("capability_tier").?.string);
}

test "capability matcher ranks validation workflow tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testApp(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "goal", .{ .string = "plan validation for changed tests" });
    const result = try validation.zigarCapabilityMatch(&app, allocator, .{ .object = args });
    const obj = result.structuredContent.?.object;

    try std.testing.expectEqualStrings("zigar_capability_match", obj.get("kind").?.string);
    try std.testing.expect(obj.get("matches").?.array.items.len > 0);
}

test "validation run previews history when no command phases are selected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testApp(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "mode", .{ .string = "quick" });
    try args.put(allocator, "changed_files", .{ .string = "notes.txt" });
    try args.put(allocator, "apply", .{ .bool = false });
    const result = try validation.zigarValidationRun(&app, allocator, .{ .object = args });
    const obj = result.structuredContent.?.object;

    try std.testing.expectEqualStrings("zigar_validation_run", obj.get("kind").?.string);
    try std.testing.expectEqual(false, obj.get("history_applied").?.bool);
    try std.testing.expectEqual(@as(i64, 0), obj.get("history_record").?.object.get("phase_count").?.integer);
    try std.testing.expect(obj.get("skipped_phases").?.array.items.len >= 1);
}

test "validation run and event tools execute bounded Zig commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "main.zig", .data = "pub fn main() void {}\ntest \"ok\" {}\n" });
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    const root_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    const root = root_z[0..];
    const ws = zigar.workspace.Workspace{ .allocator = allocator, .io = io, .root = root, .cache_root = root };
    var app = App{ .allocator = allocator, .io = io, .config = .{ .workspace = root, .zig_path = "zig", .timeout_ms = 10_000 }, .workspace = ws };

    var run_args = std.json.ObjectMap.empty;
    try run_args.put(allocator, "mode", .{ .string = "quick" });
    try run_args.put(allocator, "changed_files", .{ .string = "main.zig" });
    try run_args.put(allocator, "include_semantic", .{ .bool = false });
    try run_args.put(allocator, "apply", .{ .bool = false });
    const run = try validation.zigarValidationRun(&app, allocator, .{ .object = run_args });
    try std.testing.expect(run.structuredContent.?.object.get("phases").?.array.items.len >= 1);

    var build_args = std.json.ObjectMap.empty;
    try build_args.put(allocator, "command", .{ .string = "fmt-check" });
    try build_args.put(allocator, "file", .{ .string = "main.zig" });
    const build = try validation.zigBuildEvents(&app, allocator, .{ .object = build_args });
    try std.testing.expectEqualStrings("executed_command", build.structuredContent.?.object.get("parsing_basis").?.string);

    var test_args = std.json.ObjectMap.empty;
    try test_args.put(allocator, "command", .{ .string = "test" });
    try test_args.put(allocator, "file", .{ .string = "main.zig" });
    try test_args.put(allocator, "filter", .{ .string = "ok" });
    const test_events = try validation.zigTestEvents(&app, allocator, .{ .object = test_args });
    try std.testing.expectEqualStrings("zig_test_events", test_events.structuredContent.?.object.get("kind").?.string);
}

test "history tools summarize supplied validation records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testApp(allocator);

    var args = std.json.ObjectMap.empty;
    try args.put(allocator, "history", .{ .string =
        \\{"ok":false,"failures":[{"fingerprint":"src/main.zig:1:error","message":"boom"}],"slow_phases":[{"name":"build","duration_ms":1200}],"phases":[]}
        \\{"ok":true,"failures":[],"slow_phases":[],"phases":[]}
        \\
    });
    const runs = try validation.zigarValidationHistory(&app, allocator, .{ .object = args });
    const flakes = try validation.zigTestFlakeHistory(&app, allocator, .{ .object = args });
    const failures = try validation.zigFailureHistory(&app, allocator, .{ .object = args });

    try std.testing.expectEqualStrings("zigar_validation_history", runs.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 2), runs.structuredContent.?.object.get("run_count").?.integer);
    try std.testing.expectEqualStrings("zig_test_flake_history", flakes.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("zig_failure_history", failures.structuredContent.?.object.get("kind").?.string);
}

test "validation and decision apply gates write workspace-local history" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const rel_base = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    const root_z = try std.Io.Dir.cwd().realPathFileAlloc(io, rel_base, allocator);
    const root = root_z[0..];
    const ws = zigar.workspace.Workspace{ .allocator = allocator, .io = io, .root = root, .cache_root = root };
    var app = App{ .allocator = allocator, .io = io, .config = .{ .workspace = root, .zig_path = "zig" }, .workspace = ws };

    var run_args = std.json.ObjectMap.empty;
    try run_args.put(allocator, "mode", .{ .string = "quick" });
    try run_args.put(allocator, "changed_files", .{ .string = "notes.txt" });
    try run_args.put(allocator, "apply", .{ .bool = true });
    const run = try validation.zigarValidationRun(&app, allocator, .{ .object = run_args });
    try std.testing.expectEqual(true, run.structuredContent.?.object.get("history_applied").?.bool);
    const history = try app.workspace.readFileAlloc(io, ".zigar-cache/validation/history.jsonl", 1024 * 1024);
    try std.testing.expect(history.len > 0);

    var decision_args = std.json.ObjectMap.empty;
    try decision_args.put(allocator, "title", .{ .string = "Record decision" });
    try decision_args.put(allocator, "decision", .{ .string = "Keep history local" });
    try decision_args.put(allocator, "apply", .{ .bool = true });
    const decision = try validation.zigarDecisionRecord(&app, allocator, .{ .object = decision_args });
    try std.testing.expectEqual(true, decision.structuredContent.?.object.get("applied").?.bool);
    const memory = try app.workspace.readFileAlloc(io, ".zigar/project-memory.jsonl", 1024 * 1024);
    try std.testing.expect(memory.len > 0);
}

test "handoff, decision, and sequence tools expose read-only workflow state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var app = try testApp(allocator);

    var snapshot_args = std.json.ObjectMap.empty;
    try snapshot_args.put(allocator, "goal", .{ .string = "finish validation" });
    try snapshot_args.put(allocator, "changed_files", .{ .string = "src/main.zig" });
    const snapshot = try validation.zigarSessionSnapshot(&app, allocator, .{ .object = snapshot_args });
    const handoff = try validation.zigarHandoffPack(&app, allocator, .{ .object = snapshot_args });

    var decision_args = std.json.ObjectMap.empty;
    try decision_args.put(allocator, "title", .{ .string = "Use apply gates" });
    try decision_args.put(allocator, "decision", .{ .string = "Writes require apply=true" });
    try decision_args.put(allocator, "apply", .{ .bool = false });
    const decision = try validation.zigarDecisionRecord(&app, allocator, .{ .object = decision_args });

    var sequence_args = std.json.ObjectMap.empty;
    try sequence_args.put(allocator, "goal", .{ .string = "fix failing tests" });
    try sequence_args.put(allocator, "changed_files", .{ .string = "src/main.zig" });
    const sequence = try validation.zigarToolSequencePlan(&app, allocator, .{ .object = sequence_args });

    try std.testing.expectEqualStrings("zigar_session_snapshot", snapshot.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqualStrings("zigar_handoff_pack", handoff.structuredContent.?.object.get("kind").?.string);
    try std.testing.expectEqual(false, decision.structuredContent.?.object.get("applied").?.bool);
    try std.testing.expectEqualStrings("zigar_tool_sequence_plan", sequence.structuredContent.?.object.get("kind").?.string);
    try std.testing.expect(sequence.structuredContent.?.object.get("sequence").?.array.items.len > 0);
}
