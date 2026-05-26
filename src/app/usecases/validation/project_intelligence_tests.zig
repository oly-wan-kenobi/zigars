const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const project_intelligence = @import("project_intelligence.zig");
const validation_workflows = @import("workflows.zig");

test "project intelligence routes next action and patch guards generated paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const plan = (try project_intelligence.nextActionPlanValue(allocator, "fix compile error", "src/main.zig", "error: bad")).object;
    try std.testing.expectEqualStrings("zig_compile_error_index", plan.get("recommended_steps").?.array.items[0].object.get("tool").?.string);
}

const StubRuntime = struct {
    command_runs: usize = 0,
    writes: usize = 0,
    git_status_stdout: []const u8 = " M src/main.zig\n M build.zig.zon\n",
    command_error: ?ports.PortError = null,
    fail_on: ?[]const u8 = null,
    nonzero_on: ?[]const u8 = null,

    fn context(self: *StubRuntime) app_context.ProjectIntelligenceContext {
        return .{
            .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache", .transport = "test" },
            .tool_paths = .{ .zig = "zig" },
            .timeouts = .{ .command_ms = 30_000, .zls_ms = 30_000 },
            .zls_state = .{ .status = "connected", .running = true },
            .command_runner = self.commandPort(),
            .workspace_store = self.workspacePort(),
            .workspace_scanner = self.scannerPort(),
            .clock_and_ids = self.clockPort(),
        };
    }

    fn commandPort(self: *StubRuntime) ports.CommandRunner {
        return .{ .ptr = self, .vtable = &.{ .run = commandRun } };
    }

    fn workspacePort(self: *StubRuntime) ports.WorkspaceStore {
        return .{
            .ptr = self,
            .vtable = &.{
                .resolve = workspaceResolve,
                .read = workspaceRead,
                .write = workspaceWrite,
                .exists = workspaceExists,
            },
        };
    }

    fn scannerPort(self: *StubRuntime) ports.WorkspaceScanner {
        return .{ .ptr = self, .vtable = &.{ .scan_zig_files = scanZigFiles } };
    }

    fn clockPort(self: *StubRuntime) ports.ClockAndIds {
        return .{ .ptr = self, .vtable = &.{ .now = now, .nextId = nextId } };
    }

    fn commandRun(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.CommandRequest) ports.PortError!ports.CommandResult {
        const self: *StubRuntime = @ptrCast(@alignCast(ptr));
        self.command_runs += 1;
        const joined = try std.mem.join(allocator, " ", request.argv);
        defer allocator.free(joined);
        if (self.command_error) |err| {
            if (self.fail_on == null or std.mem.indexOf(u8, joined, self.fail_on.?) != null) return err;
        }
        const failed = if (self.nonzero_on) |needle| std.mem.indexOf(u8, joined, needle) != null else false;
        const stdout = if (std.mem.indexOf(u8, joined, "git status") != null)
            self.git_status_stdout
        else if (std.mem.indexOf(u8, joined, "build test") != null or std.mem.indexOf(u8, joined, "test") != null)
            "PASS util_test 12ms\nStep test succeeded\n"
        else
            "";
        const stderr = if (failed)
            "src/main.zig:1:1: error: failed command\n"
        else if (std.mem.indexOf(u8, joined, "ast-check") != null)
            "src/main.zig:1:1: warning: checked\n"
        else
            "";
        return .{
            .exit_code = if (failed) 1 else 0,
            .stdout = try allocator.dupe(u8, stdout),
            .stderr = try allocator.dupe(u8, stderr),
            .duration_ms = 12,
            .owns_stdout = true,
            .owns_stderr = true,
        };
    }

    fn workspaceResolve(_: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceResolveRequest) ports.PortError!ports.WorkspaceResolveResult {
        if (std.mem.indexOf(u8, request.path, "..") != null) return error.PathOutsideWorkspace;
        return .{ .path = try std.fmt.allocPrint(allocator, "/repo/{s}", .{request.path}), .owns_path = true };
    }

    fn workspaceRead(_: *anyopaque, allocator: std.mem.Allocator, request: ports.WorkspaceReadRequest) ports.PortError!ports.WorkspaceReadResult {
        const bytes = if (std.mem.eql(u8, request.path, "build.zig"))
            \\const std = @import("std");
            \\pub fn build(b: *std.Build) void {
            \\    const exe = b.addExecutable(.{ .name = "app", .root_source_file = b.path("src/main.zig") });
            \\    const tests = b.addTest(.{ .root_source_file = b.path("tests/util_test.zig") });
            \\    _ = b.step("smoke", "run smoke");
            \\}
        else if (std.mem.eql(u8, request.path, "build.zig.zon"))
            \\.{
            \\    .name = .fixture,
            \\    .dependencies = .{
            \\        .dep = .{ .url = "https://example.invalid/dep.tar.gz", .hash = "abc" },
            \\    },
            \\    .paths = .{ "src", "build.zig" },
            \\}
        else if (std.mem.eql(u8, request.path, "src/main.zig"))
            \\const util = @import("util.zig");
            \\pub fn main() void { util.run(); }
        else if (std.mem.eql(u8, request.path, "src/util.zig"))
            \\pub fn run() void {}
            \\pub const Api = struct {};
        else if (std.mem.eql(u8, request.path, "tests/util_test.zig"))
            \\const util = @import("../src/util.zig");
            \\test "run" { util.run(); }
        else if (std.mem.eql(u8, request.path, ".zigar/profile.v2.json"))
            \\{"schema_version":2}
        else if (std.mem.eql(u8, request.path, ".zigar/profile.json"))
            \\{"schema_version":1,"existing":true}
        else if (std.mem.eql(u8, request.path, ".zigar/project-memory.jsonl"))
            \\{"category":"architecture","title":"Existing","decision":"Keep hex ports","rationale":"testing"}
        else
            return error.FileNotFound;
        return .{ .bytes = try allocator.dupe(u8, bytes), .owns_bytes = true };
    }

    fn workspaceWrite(ptr: *anyopaque, request: ports.WorkspaceWriteRequest) ports.PortError!ports.WorkspaceWriteResult {
        const self: *StubRuntime = @ptrCast(@alignCast(ptr));
        self.writes += 1;
        return .{ .bytes_written = request.bytes.len };
    }

    fn workspaceExists(_: *anyopaque, _: std.mem.Allocator, request: ports.WorkspaceExistsRequest) ports.PortError!ports.WorkspaceExistsResult {
        const exists = std.mem.eql(u8, request.path, "build.zig") or
            std.mem.eql(u8, request.path, "build.zig.zon") or
            std.mem.eql(u8, request.path, "src") or
            std.mem.eql(u8, request.path, "src/main.zig") or
            std.mem.eql(u8, request.path, "src/util.zig") or
            std.mem.eql(u8, request.path, "tests/util_test.zig");
        return .{ .exists = exists, .kind = if (std.mem.eql(u8, request.path, "src")) .directory else .file };
    }

    fn scanZigFiles(_: *anyopaque, allocator: std.mem.Allocator, _: ports.WorkspaceScanRequest) ports.PortError!ports.WorkspaceScanResult {
        const names = [_][]const u8{ "src/main.zig", "src/util.zig", "tests/util_test.zig" };
        const files = try allocator.alloc(ports.WorkspaceScanFile, names.len);
        errdefer allocator.free(files);
        for (names, 0..) |name, index| files[index] = .{ .path = try allocator.dupe(u8, name) };
        return .{ .files = files, .owns_memory = true };
    }

    fn now(_: *anyopaque) ports.PortError!ports.Instant {
        return .{ .unix_ms = 1_700_000_000_000, .monotonic_ms = 42 };
    }

    fn nextId(_: *anyopaque, allocator: std.mem.Allocator, request: ports.IdRequest) ports.PortError![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}-0001", .{request.prefix});
    }
};

test "project intelligence routes pure planning, events, memory, and capabilities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime = StubRuntime{};
    const context = runtime.context();

    var failing_scan = std.testing.FailingAllocator.init(arena.allocator(), .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, StubRuntime.scanZigFiles(&runtime, failing_scan.allocator(), .{}));
    const generated_id = try StubRuntime.nextId(&runtime, allocator, .{ .prefix = "project" });
    try std.testing.expectEqualStrings("project-0001", generated_id);

    const guide = (try project_intelligence.agentGuideValue(allocator, "codex", "fix failing test")).object;
    try std.testing.expectEqualStrings("zigar_agent_guide", guide.get("kind").?.string);

    const build_plan = (try project_intelligence.nextActionPlanValue(allocator, "fix compile error", "src/main.zig", null)).object;
    try std.testing.expectEqualStrings("zig_compile_error_index", build_plan.get("recommended_steps").?.array.items[0].object.get("tool").?.string);
    const profile_plan = (try project_intelligence.nextActionPlanValue(allocator, "profile flamegraph", null, null)).object;
    try std.testing.expectEqualStrings("zig_profile_plan", profile_plan.get("recommended_steps").?.array.items[0].object.get("tool").?.string);

    const events = (try project_intelligence.commandEventsValue(allocator, context, "zig_build_events", .{
        .text = "src/main.zig:1:1: error: bad\nwarning: slow\nFAIL util_test\nPASS other_test 12ms\nStep test failed\n",
        .timeout_ms = 10,
        .kind = .build,
    })).object;
    try std.testing.expect(events.get("events").?.array.items.len >= 4);
    const timing = (try project_intelligence.testTimingValue(allocator, "PASS util_test 12ms\nslow case 340ms\n")).object;
    try std.testing.expectEqual(@as(usize, 2), timing.get("timings").?.array.items.len);

    const memory = (try project_intelligence.projectMemoryValue(allocator, context, .{
        .content =
        \\{"category":"architecture","title":"Hex","decision":"Use typed app use cases","rationale":"boundary"}
        \\{"category":"notes","title":"Skip","decision":"Other"}
        ,
        .query = "typed",
        .category = "architecture",
        .include_builtins = true,
        .tool_name = "zigar_project_memory",
    })).object;
    try std.testing.expectEqual(@as(i64, 1), memory.get("note_count").?.integer);
    try std.testing.expect(memory.get("built_in_project_policies").?.array.items.len >= 1);

    const risk = project_intelligence.ToolRisk{
        .level = "medium",
        .mcp_read_only_hint = true,
        .writes_source = false,
        .writes_artifacts = false,
        .writes_require_apply = false,
        .preview_by_default = true,
        .mutates_lsp_state = false,
        .executes_project_code = false,
        .executes_user_command = false,
        .executes_backend = false,
    };
    const matches = (try project_intelligence.capabilityMatchValue(allocator, "semantic impact tests", 2, &.{
        .{ .name = "zig_impact_semantic", .description = "semantic impact and test selection", .group = "validation", .group_keywords = &.{ "semantic", "tests" }, .risk = risk, .plan_kind = "read" },
        .{ .name = "zig_format", .description = "format source", .group = "editing", .group_keywords = &.{"format"}, .risk = risk, .plan_kind = "mutate" },
    })).object;
    try std.testing.expectEqualStrings("zig_impact_semantic", matches.get("matches").?.array.items[0].object.get("tool").?.string);

    const sequence = (try project_intelligence.toolSequencePlanValue(allocator, "impact changed files", "src/main.zig")).object;
    try std.testing.expectEqualStrings("zig_impact_semantic", sequence.get("sequence").?.array.items[0].object.get("tool").?.string);
}

test "project intelligence validates patches, impact, profiles, and patch guard through typed ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime = StubRuntime{};
    const context = runtime.context();

    const validation = (try project_intelligence.validatePatchValue(allocator, context, .{
        .mode = "full",
        .changed_files = "src/main.zig build.zig.zon",
        .timeout_ms = 1000,
    })).object;
    try std.testing.expect(validation.get("ok").?.bool);
    try std.testing.expect(validation.get("phases").?.array.items.len >= 3);
    try std.testing.expect(validation.get("ran_full_build_test").?.bool);

    const impact = (try project_intelligence.impactValue(allocator, context, .{
        .files = "src/util.zig",
        .symbols = "run",
        .limit = 10,
    })).object;
    try std.testing.expect(impact.get("likely_tests").?.array.items.len >= 1);
    try std.testing.expect(impact.get("recommended_commands").?.array.items.len >= 1);

    const guard = (try project_intelligence.patchGuardValue(allocator, context, .{
        .patch =
        \\diff --git a/src/main.zig b/src/main.zig
        \\--- a/src/main.zig
        \\+++ b/src/main.zig
        \\diff --git a/zig-out/generated.zig b/zig-out/generated.zig
        \\--- a/zig-out/generated.zig
        \\+++ b/zig-out/generated.zig
        ,
    })).object;
    try std.testing.expect(!guard.get("safe").?.bool);
    try std.testing.expectEqual(@as(usize, 1), guard.get("violations").?.array.items.len);

    const profile = (try project_intelligence.projectProfileValue(allocator, context, .{ .apply = true })).object;
    try std.testing.expect(profile.get("applied").?.bool);
    try std.testing.expect(runtime.writes >= 1);
}

test "project intelligence derives semantic impact and focused tests from source scans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime = StubRuntime{};
    const context = runtime.context();

    const semantic = (try project_intelligence.semanticImpactValue(allocator, context, .{
        .files = "src/util.zig",
        .symbols = "run Api",
        .limit = 20,
    }, "zig_impact_semantic")).object;
    try std.testing.expectEqualStrings("zig_impact_semantic", semantic.get("kind").?.string);
    try std.testing.expect(semantic.get("affected_tests").?.array.items.len >= 1);
    try std.testing.expect(semantic.get("recommended_checks").?.array.items.len >= 1);

    const selected = (try project_intelligence.testSelectSemanticValue(allocator, context, .{
        .diff =
        \\diff --git a/src/util.zig b/src/util.zig
        \\--- a/src/util.zig
        \\+++ b/src/util.zig
        ,
        .symbols = "run",
        .limit = 20,
    })).object;
    try std.testing.expectEqualStrings("zig_test_select_semantic", selected.get("kind").?.string);
    try std.testing.expect(selected.get("commands").?.array.items.len >= 1);
}

test "project intelligence snapshots handoff and decision records with preimage identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime = StubRuntime{};
    const context = runtime.context();

    const snapshot = (try project_intelligence.sessionSnapshotValue(allocator, context, .{
        .kind = "zigar_session_snapshot",
        .goal = "finish ARCH-109",
        .changed_files = "src/app/usecases/validation/project_intelligence.zig",
        .diff =
        \\diff --git a/src/app/usecases/validation/project_intelligence.zig b/src/app/usecases/validation/project_intelligence.zig
        \\--- a/src/app/usecases/validation/project_intelligence.zig
        \\+++ b/src/app/usecases/validation/project_intelligence.zig
        ,
        .validation = "{\"ok\":true}",
        .last_error = null,
    })).object;
    try std.testing.expectEqualStrings("zigar_session_snapshot", snapshot.get("kind").?.string);
    try std.testing.expect(snapshot.get("profile_state").?.object.get("profile_v2_present").?.bool);

    const handoff = (try project_intelligence.handoffPackValue(allocator, context, .{
        .kind = "ignored",
        .goal = "finish ARCH-109",
        .changed_files = "src/app/usecases/validation/project_intelligence.zig",
    })).object;
    try std.testing.expectEqualStrings("zigar_handoff_pack", handoff.get("kind").?.string);

    const decision = (try project_intelligence.decisionRecordValue(allocator, context, .{
        .title = "Move project intelligence",
        .decision = "Use app use cases and MCP projection",
        .rationale = "ARCH-109 boundary closure",
        .apply = true,
    })).object;
    try std.testing.expect(decision.get("applied").?.bool);
    try std.testing.expect(runtime.writes >= 1);
}

test "project intelligence covers command, path, and validation projection edge cases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime = StubRuntime{};
    const context = runtime.context();

    const auto_validation = (try project_intelligence.validatePatchValue(allocator, context, .{
        .mode = "quick",
        .changed_files = null,
        .timeout_ms = 1000,
    })).object;
    try std.testing.expectEqualStrings("zigar_validate_patch", auto_validation.get("kind").?.string);
    try std.testing.expect(auto_validation.get("phases").?.array.items.len >= 2);
    try std.testing.expect(!auto_validation.get("ran_full_build_test").?.bool);

    const guard = (try project_intelligence.patchGuardValue(allocator, context, .{
        .files = "../secret src/main.zig",
    })).object;
    try std.testing.expect(!guard.get("safe").?.bool);
    try std.testing.expectEqual(@as(usize, 1), guard.get("violations").?.array.items.len);

    const fusion = (try project_intelligence.failureFusionFromCommandValue(allocator, context, .{
        .command = "check",
        .file = "src/main.zig",
        .timeout_ms = 1000,
    })).object;
    try std.testing.expectEqualStrings("zigar_failure_fusion", fusion.get("kind").?.string);
    try std.testing.expect(fusion.get("compiler") != null);
    try std.testing.expect(fusion.get("suggested_tools").?.array.items.len >= 3);

    const events = (try project_intelligence.commandEventsValue(allocator, context, "zig_test_events", .{
        .command = "test",
        .file = "tests/util_test.zig",
        .filter = "run",
        .extra_args = &.{"--summary"},
        .timeout_ms = 1000,
        .kind = .test_cmd,
    })).object;
    try std.testing.expectEqualStrings("executed_command", events.get("parsing_basis").?.string);
    try std.testing.expect(events.get("summary").?.object.get("event_count").?.integer >= 1);

    const profile_from_content = (try project_intelligence.projectProfileValue(allocator, context, .{
        .content = "{\"schema_version\":9,\"custom\":true}",
        .apply = false,
    })).object;
    try std.testing.expect(profile_from_content.get("requires_apply").?.bool);

    const memory_from_file = (try project_intelligence.projectMemoryValue(allocator, context, .{
        .path = project_intelligence.memory_path_default,
        .query = "hex",
        .category = "architecture",
        .limit = 2,
        .include_builtins = false,
        .tool_name = "zigar_project_memory",
    })).object;
    try std.testing.expect(memory_from_file.get("memory_available").?.bool);

    const handoff_sequence = (try project_intelligence.toolSequencePlanValue(allocator, "resume handoff", null)).object;
    try std.testing.expectEqualStrings("zigar_session_snapshot", handoff_sequence.get("sequence").?.array.items[0].object.get("tool").?.string);
    const default_sequence = (try project_intelligence.toolSequencePlanValue(allocator, "orient workspace", null)).object;
    try std.testing.expectEqualStrings("zigar_capability_match", default_sequence.get("sequence").?.array.items[0].object.get("tool").?.string);
}

test "project intelligence renders validation plans, runs, and history records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const phase_argv = validation_workflows.OwnedArgv{ .items = &.{ "zig", "build", "test" } };
    const check_argv = validation_workflows.OwnedArgv{ .items = &.{ "zig", "ast-check", "src/main.zig" } };
    var phases = [_]validation_workflows.Phase{
        .{ .id = "fmt", .kind = .command, .tool = "zig_format_check", .argv = phase_argv, .reason = "format changed source", .required = true, .risk = "medium" },
        .{ .id = "review", .kind = .tool_only, .tool = null, .argv = null, .reason = "inspect advisory evidence", .required = false, .risk = "low" },
    };
    var skipped = [_]validation_workflows.SkippedPhase{
        .{ .name = "coverage", .reason = "not requested" },
    };
    const facts = validation_workflows.OwnedStringList{ .items = &.{ "src/main.zig changed", "build.zig exists" } };
    const unknowns = validation_workflows.OwnedStringList{ .items = &.{"coverage not run"} };
    const plan = validation_workflows.PlanResult{
        .plan_id = "plan-1",
        .mode = "standard",
        .goal = "fix test",
        .facts = facts,
        .risk = .{ .changed_file_count = 2, .touches_zig_source = true, .touches_build_config = true, .touches_docs = false, .level = "high" },
        .phases = phases[0..],
        .skipped_phases = skipped[0..],
        .unknowns = unknowns,
    };

    const plan_value = (try project_intelligence.validationPlanValueFromUsecase(allocator, plan)).object;
    try std.testing.expectEqualStrings("zigar_validation_plan", plan_value.get("kind").?.string);
    try std.testing.expectEqual(@as(usize, 2), plan_value.get("phases").?.array.items.len);

    var phase_runs = [_]validation_workflows.PhaseRun{
        .{
            .name = "build_test",
            .ok = false,
            .argv = phase_argv,
            .cwd = "/repo",
            .timeout_ms = 1000,
            .outcome = .{ .result = .{
                .exit_code = 1,
                .term = .{ .exited = 1 },
                .stdout = "PASS other_test 12ms\n",
                .stderr = "src/main.zig:1:1: error: bad\n1/1 test.foo...FAIL (TestExpectedEqual)\nStep test failed\nslow case 340ms\n",
                .duration_ms = 340,
                .timed_out = false,
                .stdout_truncated = true,
                .stderr_truncated = false,
            } },
        },
        .{
            .name = "ast_check",
            .ok = false,
            .argv = check_argv,
            .cwd = "/repo",
            .timeout_ms = 1000,
            .outcome = .{ .port_error = error.Timeout },
        },
    };
    var failures = [_]validation_workflows.FailureRecord{
        .{ .phase = "build_test", .fingerprint = "src/main.zig:error:bad" },
    };
    var slow = [_]validation_workflows.SlowPhase{
        .{ .phase = "build_test", .duration_ms = 340 },
    };
    const record = validation_workflows.HistoryRecord{
        .recorded_unix_ms = 1_700_000_000_000,
        .ok = false,
        .plan_id = "plan-1",
        .phase_count = 2,
        .skipped_count = 1,
        .failures = failures[0..],
        .slow_phases = slow[0..],
    };
    const report = validation_workflows.RunReport{
        .ok = false,
        .plan = plan,
        .phases = phase_runs[0..],
        .skipped_phases = skipped[0..],
        .history_record = record,
        .history_path = ".zigar-cache/validation/history.jsonl",
        .history_applied = false,
        .requires_apply_for_history = true,
        .preimage_identity = .{ .exists = true, .bytes = 12, .sha256 = "abc" },
    };
    const run = (try project_intelligence.validationRunValue(allocator, report)).object;
    try std.testing.expectEqualStrings("zigar_validation_run", run.get("kind").?.string);
    try std.testing.expect(!run.get("ok").?.bool);
    try std.testing.expectEqual(@as(usize, 2), run.get("phases").?.array.items.len);

    var no_history_failures = [_]validation_workflows.HistoryFailure{};
    var runs = [_]validation_workflows.HistoryRun{
        .{ .raw_json = "{\"ok\":false,\"id\":1}", .ok = false, .failures = no_history_failures[0..] },
        .{ .raw_json = "not-json", .ok = true, .failures = no_history_failures[0..] },
    };
    var groups = [_]validation_workflows.FailureGroup{
        .{ .fingerprint = "src/main.zig:error:bad", .count = 2, .sample_json = "{\"phase\":\"build_test\"}" },
        .{ .fingerprint = "raw", .count = 1, .sample_json = "not-json" },
    };
    const history = validation_workflows.HistoryResult{
        .view = .runs,
        .history_available = true,
        .runs = runs[0..],
        .last_run_index = 0,
        .last_good_index = 1,
        .failure_groups = groups[0..],
    };
    const runs_value = (try project_intelligence.validationHistoryToolValue(allocator, "zigar_validation_history", history)).object;
    try std.testing.expectEqual(@as(i64, 2), runs_value.get("run_count").?.integer);

    var flakes_history = history;
    flakes_history.view = .flakes;
    const flakes = (try project_intelligence.validationHistoryToolValue(allocator, "zigar_validation_flakes", flakes_history)).object;
    try std.testing.expectEqualStrings("zigar_validation_flakes", flakes.get("kind").?.string);

    var failures_history = history;
    failures_history.view = .failures;
    const recurring = (try project_intelligence.validationHistoryToolValue(allocator, "zigar_validation_failures", failures_history)).object;
    try std.testing.expectEqual(@as(i64, 2), recurring.get("run_count").?.integer);
}

test "project intelligence covers context packs and routing fallbacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime = StubRuntime{};
    const context = runtime.context();

    const pack = (try project_intelligence.contextPackValue(allocator, context, .{
        .mode = "deep",
        .token_budget = 100_000,
    })).object;
    try std.testing.expectEqualStrings("zigar_context_pack", pack.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 50_000), pack.get("token_budget").?.integer);
    try std.testing.expect(pack.get("tests") != null);
    try std.testing.expect(pack.get("deps") != null);

    const format_plan = (try project_intelligence.nextActionPlanValue(allocator, "format touched files", null, null)).object;
    try std.testing.expectEqualStrings("zig_format_check", format_plan.get("recommended_steps").?.array.items[0].object.get("tool").?.string);
    const review_plan = (try project_intelligence.nextActionPlanValue(allocator, "review PR done", null, null)).object;
    try std.testing.expectEqualStrings("zigar_validate_patch", review_plan.get("recommended_steps").?.array.items[0].object.get("tool").?.string);
    const test_sequence = (try project_intelligence.toolSequencePlanValue(allocator, "fix failing tests", null)).object;
    try std.testing.expectEqualStrings("zig_test_events", test_sequence.get("sequence").?.array.items[0].object.get("tool").?.string);

    const phases = std.json.Array.init(allocator);
    const blocked = (try project_intelligence.validationNextActionValue(allocator, false, phases)).object;
    try std.testing.expectEqualStrings("zigar_validate_patch", blocked.get("tool").?.string);

    var compiler_summary = std.json.ObjectMap.empty;
    try compiler_summary.put(allocator, "primary", .{ .string = "compile-primary" });
    var compiler = std.json.ObjectMap.empty;
    try compiler.put(allocator, "summary", .{ .object = compiler_summary });
    try std.testing.expectEqualStrings("compile-primary", (try project_intelligence.primaryFailureValue(allocator, .{ .object = compiler }, .null)).string);

    var failure_item = std.json.ObjectMap.empty;
    try failure_item.put(allocator, "name", .{ .string = "unit fails" });
    var failures = std.json.Array.init(allocator);
    try failures.append(.{ .object = failure_item });
    var tests_obj = std.json.ObjectMap.empty;
    try tests_obj.put(allocator, "failures", .{ .array = failures });
    const primary_from_tests = (try project_intelligence.primaryFailureValue(allocator, .{ .object = std.json.ObjectMap.empty }, .{ .object = tests_obj })).object;
    try std.testing.expectEqualStrings("unit fails", primary_from_tests.get("name").?.string);
}

test "project intelligence covers failed validation command paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var fmt_runtime = StubRuntime{ .nonzero_on = "fmt --check src/main.zig" };
    const fmt_failed = (try project_intelligence.validatePatchValue(allocator, fmt_runtime.context(), .{
        .mode = "quick",
        .changed_files = "src/main.zig",
        .timeout_ms = 1000,
        .stop_on_failure = true,
    })).object;
    try std.testing.expect(!fmt_failed.get("ok").?.bool);

    var ast_runtime = StubRuntime{ .nonzero_on = "ast-check" };
    const ast_failed = (try project_intelligence.validatePatchValue(allocator, ast_runtime.context(), .{
        .mode = "quick",
        .changed_files = "src/main.zig",
        .timeout_ms = 1000,
    })).object;
    try std.testing.expect(!ast_failed.get("ok").?.bool);

    var empty_runtime = StubRuntime{ .git_status_stdout = "" };
    const workspace_fmt = (try project_intelligence.validatePatchValue(allocator, empty_runtime.context(), .{
        .mode = "quick",
        .changed_files = null,
        .timeout_ms = 1000,
    })).object;
    try std.testing.expectEqualStrings("workspace_format_check", workspace_fmt.get("phases").?.array.items[0].object.get("name").?.string);

    var failing_workspace_runtime = StubRuntime{ .git_status_stdout = "", .nonzero_on = "fmt --check" };
    const workspace_failed = (try project_intelligence.validatePatchValue(allocator, failing_workspace_runtime.context(), .{
        .mode = "quick",
        .changed_files = null,
        .timeout_ms = 1000,
        .stop_on_failure = true,
    })).object;
    try std.testing.expect(!workspace_failed.get("ok").?.bool);

    var port_error_runtime = StubRuntime{ .command_error = error.StreamTooLong, .fail_on = "fmt" };
    const stream_limited = (try project_intelligence.validatePatchValue(allocator, port_error_runtime.context(), .{
        .mode = "quick",
        .changed_files = "src/main.zig",
        .timeout_ms = 1000,
    })).object;
    const command = stream_limited.get("phases").?.array.items[0].object.get("command").?.object;
    try std.testing.expect(command.get("output_limit_exceeded").?.bool);
    try std.testing.expect(command.get("note") != null);
}

test "project intelligence covers command construction and fallback data paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var runtime = StubRuntime{};
    const context = runtime.context();

    const build_fusion = (try project_intelligence.failureFusionFromCommandValue(allocator, context, .{
        .command = "build",
        .timeout_ms = 1000,
    })).object;
    try std.testing.expectEqualStrings("zigar_failure_fusion", build_fusion.get("kind").?.string);

    const default_fusion = (try project_intelligence.failureFusionFromCommandValue(allocator, context, .{
        .timeout_ms = 1000,
    })).object;
    try std.testing.expectEqualStrings("zigar_failure_fusion", default_fusion.get("kind").?.string);

    const fmt_events = (try project_intelligence.commandEventsValue(allocator, context, "zig_build_events", .{
        .command = "fmt-check",
        .timeout_ms = 1000,
        .kind = .build,
    })).object;
    try std.testing.expectEqualStrings("executed_command", fmt_events.get("parsing_basis").?.string);

    const empty_semantic = (try project_intelligence.semanticImpactValue(allocator, context, .{}, "zig_impact_semantic")).object;
    try std.testing.expect(empty_semantic.get("unknowns").?.array.items.len >= 1);

    const memory_array = (try project_intelligence.projectMemoryValue(allocator, context, .{
        .content =
        \\[
        \\  {"category":"architecture","title":"Array","decision":"Use JSON arrays"},
        \\  {"category":"notes","title":"Skip","decision":"Other"}
        \\]
        ,
        .category = "architecture",
        .limit = 1,
        .tool_name = "zigar_project_memory",
    })).object;
    try std.testing.expectEqual(@as(i64, 1), memory_array.get("note_count").?.integer);

    const missing_memory = (try project_intelligence.projectMemoryValue(allocator, context, .{
        .path = ".zigar/missing.jsonl",
        .limit = 10,
        .tool_name = "zigar_project_memory",
    })).object;
    try std.testing.expect(!missing_memory.get("memory_available").?.bool);
    try std.testing.expectEqual(@as(i64, 0), missing_memory.get("note_count").?.integer);
}
