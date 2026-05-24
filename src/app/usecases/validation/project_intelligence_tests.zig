const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const project_intelligence = @import("project_intelligence.zig");

const StubRuntime = struct {
    command_runs: usize = 0,
    writes: usize = 0,

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
        const stdout = if (std.mem.indexOf(u8, joined, "git status") != null)
            " M src/main.zig\n M build.zig.zon\n"
        else if (std.mem.indexOf(u8, joined, "build test") != null or std.mem.indexOf(u8, joined, "test") != null)
            "PASS util_test 12ms\nStep test succeeded\n"
        else
            "";
        const stderr = if (std.mem.indexOf(u8, joined, "ast-check") != null)
            "src/main.zig:1:1: warning: checked\n"
        else
            "";
        return .{
            .exit_code = 0,
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
