const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const workflows = @import("workflows.zig");
const fakes = @import("../../../testing/fakes/root.zig");

fn testContext(
    command_runner: *fakes.FakeCommandRunner,
    workspace_store: *fakes.FakeWorkspaceStore,
    workspace_scanner: *fakes.FakeWorkspaceScanner,
    runtime_session: *fakes.FakeRuntimeSession,
    tool_catalog: *fakes.FakeToolCatalog,
) app_context.RuntimeUxContext {
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache" },
        .tool_paths = .{ .zig = "/bin/zig" },
        .timeouts = .{ .command_ms = 1000, .zls_ms = 2000 },
        .zls_state = .{},
        .command_runner = command_runner.port(),
        .workspace_store = workspace_store.port(),
        .workspace_scanner = workspace_scanner.port(),
        .runtime_session = runtime_session.port(),
        .tool_catalog = tool_catalog.port(),
    };
}

fn expectWorkspaceMapExists(workspace: *fakes.FakeWorkspaceStore) !void {
    try workspace.expectExists(.{ .path = "build.zig", .provenance = "runtime_ux.workspace_map" }, .{ .exists = true, .kind = .file });
    try workspace.expectExists(.{ .path = "build.zig.zon", .provenance = "runtime_ux.workspace_map" }, .{ .exists = false });
    try workspace.expectExists(.{ .path = "src", .provenance = "runtime_ux.workspace_map" }, .{ .exists = true, .kind = .directory });
}

test "runtime UX run job delegates command execution through ports" {
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var session = fakes.FakeRuntimeSession{};
    defer session.deinit(std.testing.allocator);
    var catalog = fakes.FakeToolCatalog.init("{}");
    const context = testContext(&commands, &workspace, &scanner, &session, &catalog);

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "build" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .provenance = "zigar_job_start",
    }, .{
        .exit_code = 0,
        .term = .{ .exited = 0 },
        .stdout = "ok\n",
        .stderr = "",
        .duration_ms = 7,
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try workflows.runJobValue(arena.allocator(), context, .{
        .tool_name = "zigar_job_start",
        .command = "build",
        .timeout_ms = 1000,
    });

    const obj = value.object;
    try std.testing.expect(obj.get("ok").?.bool);
    try std.testing.expectEqualStrings("job-1", obj.get("job_id").?.string);
    try std.testing.expectEqualStrings("ok\n", obj.get("stdout_tail").?.string);
    try commands.verify();
}

test "runtime UX job lifecycle values come from runtime session port" {
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var session = fakes.FakeRuntimeSession{};
    defer session.deinit(std.testing.allocator);
    var catalog = fakes.FakeToolCatalog.init("{}");
    const context = testContext(&commands, &workspace, &scanner, &session, &catalog);

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "build", "test" },
        .cwd = "/repo",
        .timeout_ms = 500,
        .provenance = "zigar_run_stream",
    }, .{
        .exit_code = 0,
        .term = .{ .exited = 0 },
        .stdout = "tests ok\n",
        .stderr = "",
        .duration_ms = 11,
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    _ = try workflows.runJobValue(arena.allocator(), context, .{
        .tool_name = "zigar_run_stream",
        .command = "build-test",
        .timeout_ms = 500,
        .include_events = true,
    });

    const status = try workflows.jobStatusValue(arena.allocator(), context, "job-1");
    try std.testing.expect(status.object.get("result_available").?.bool);

    const result = try workflows.jobResultValue(arena.allocator(), context, .{ .job_id = "job-1", .limit = 1 });
    try std.testing.expectEqualStrings("tests ok\n", result.object.get("stdout_tail").?.string);

    const events = try workflows.runEventsValue(arena.allocator(), context, .{ .job_id = "job-1", .limit = 1 });
    try std.testing.expectEqualStrings("zigar_run_events", events.object.get("kind").?.string);

    const jobs_resource = try workflows.jobsResourceValue(arena.allocator(), context);
    try std.testing.expectEqual(@as(i64, 1), jobs_resource.object.get("job_count").?.integer);

    const run_events_resource = try workflows.runEventsResourceValue(arena.allocator(), context);
    try std.testing.expectEqual(@as(i64, 2), run_events_resource.object.get("event_count").?.integer);

    const jobs_query = try workflows.resourceQueryValue(arena.allocator(), context, .{ .uri = "zigar://jobs", .limit = 1 });
    try std.testing.expectEqual(@as(i64, 1), jobs_query.object.get("job_count").?.integer);

    const all_events_query = try workflows.resourceQueryValue(arena.allocator(), context, .{ .uri = "zigar://run/events" });
    try std.testing.expectEqualStrings("zigar://run/events", all_events_query.object.get("uri").?.string);

    const cancel = try workflows.jobCancelValue(arena.allocator(), context, "job-1", "done");
    try std.testing.expect(cancel.object.get("ok").?.bool);

    const cancel_status = try workflows.cancelStatusValue(arena.allocator(), context, null);
    try std.testing.expectEqual(@as(i64, 1), cancel_status.object.get("job_count").?.integer);
    try commands.verify();
}

test "runtime UX workspace map and catalog use typed ports" {
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var session = fakes.FakeRuntimeSession{};
    defer session.deinit(std.testing.allocator);
    var catalog = fakes.FakeToolCatalog.init("{\"groups\":[]}");
    const context = testContext(&commands, &workspace, &scanner, &session, &catalog);

    try expectWorkspaceMapExists(&workspace);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const map_value = try workflows.workspaceMapResultValue(arena.allocator(), context, "zigar_workspace_map", null);
    const workspace_value = map_value.object.get("workspace").?.object;
    try std.testing.expectEqual(@as(i64, 1), workspace_value.get("root_count").?.integer);
    try std.testing.expectEqual(@as(usize, 2), workspace_value.get("entry_points").?.array.items.len);

    const rendered = try workflows.catalogResourceText(arena.allocator(), context);
    try std.testing.expectEqualStrings("{\"groups\":[]}", rendered);
    try std.testing.expectEqual(@as(usize, 1), catalog.calls);
    try workspace.verify();
}

test "runtime UX roots and subscription values use runtime session port" {
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var session = fakes.FakeRuntimeSession{};
    defer session.deinit(std.testing.allocator);
    var catalog = fakes.FakeToolCatalog.init("{}");
    const context = testContext(&commands, &workspace, &scanner, &session, &catalog);

    try expectWorkspaceMapExists(&workspace);
    try expectWorkspaceMapExists(&workspace);
    try expectWorkspaceMapExists(&workspace);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const preview = try workflows.rootsSyncValue(arena.allocator(), context, "file:///repo\n/tmp/other", false);
    try std.testing.expect(!preview.object.get("changed").?.bool);

    const applied = try workflows.rootsSyncValue(arena.allocator(), context, "file:///repo\n/tmp/other", true);
    try std.testing.expect(applied.object.get("changed").?.bool);

    const roots = try workflows.workspaceRootsResourceValue(arena.allocator(), context);
    try std.testing.expectEqualStrings("root-1", roots.object.get("selected_root_id").?.string);

    const selected = try workflows.workspaceSelectValue(arena.allocator(), context, "/tmp/other", true);
    try std.testing.expect(selected.object.get("apply").?.bool);

    const roots_query = try workflows.resourceQueryValue(arena.allocator(), context, .{ .uri = "zigar://workspace/roots" });
    try std.testing.expectEqualStrings("zigar://workspace/roots", roots_query.object.get("uri").?.string);

    const subscribed = try workflows.resourceSubscribeValue(arena.allocator(), context, "zigar://jobs");
    const sub_id = subscribed.object.get("subscription").?.object.get("subscription_id").?.string;
    const unsubscribed = try workflows.resourceUnsubscribeValue(arena.allocator(), context, sub_id, null);
    try std.testing.expect(!unsubscribed.object.get("subscription").?.object.get("active").?.bool);
    try workspace.verify();
}

test "runtime UX dynamic file resources read through workspace store" {
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var session = fakes.FakeRuntimeSession{};
    defer session.deinit(std.testing.allocator);
    var catalog = fakes.FakeToolCatalog.init("{}");
    const context = testContext(&commands, &workspace, &scanner, &session, &catalog);

    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = workflows.max_resource_read,
        .provenance = "runtime_ux.dynamic_resource",
    },
        \\const std = @import("std");
        \\pub fn main() void {}
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try workflows.dynamicResourceValue(arena.allocator(), context, "zigar://file/src/main.zig/imports");
    const obj = value.object;
    try std.testing.expectEqualStrings("zigar_dynamic_file_resource", obj.get("kind").?.string);
    try std.testing.expectEqualStrings("imports", obj.get("resource_kind").?.string);
    try workspace.verify();
}

test "runtime UX guidance, metrics, prompts, and import graph render from app layer" {
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var session = fakes.FakeRuntimeSession{};
    defer session.deinit(std.testing.allocator);
    var catalog = fakes.FakeToolCatalog.init("{}");
    var context = testContext(&commands, &workspace, &scanner, &session, &catalog);
    var command_calls: u64 = 3;
    var zls_requests: u64 = 2;
    var tool_errors: u64 = 1;
    context.counters.command_calls = &command_calls;
    context.counters.zls_requests = &zls_requests;
    context.counters.tool_errors = &tool_errors;
    context.caches.backend_probe.zig = true;
    context.caches.analysis = .{ .cached = true, .signature = 0xabc, .hits = 4, .refreshes = 1 };

    try scanner.expectScan(.{ .max_files = workflows.max_roots * 12 + 8, .provenance = "static_analysis.import_graph" }, &.{"src/main.zig"});
    try workspace.expectRead(.{
        .path = "src/main.zig",
        .max_bytes = 512 * 1024,
        .provenance = "static_analysis.import_graph",
    },
        \\const std = @import("std");
        \\const local = @import("local.zig");
    );

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const agent = try workflows.agentGuideV2Value(arena.allocator(), "codex", "fix");
    try std.testing.expectEqualStrings("codex", agent.object.get("client").?.string);

    const client = try workflows.clientGuideValue(arena.allocator(), "mcp", "discover");
    try std.testing.expectEqualStrings("mcp", client.object.get("client").?.string);

    const pack = try workflows.promptPackValue(arena.allocator(), "zigar_perf_workflow", "deep");
    try std.testing.expectEqual(@as(i64, 1), pack.object.get("workflow_count").?.integer);

    const prompt_query = try workflows.resourceQueryValue(arena.allocator(), context, .{ .uri = "zigar://prompts", .mode = "deep" });
    try std.testing.expectEqualStrings("zigar_prompt_pack", prompt_query.object.get("kind").?.string);

    const workspace_text = try workflows.workspaceResourceText(arena.allocator(), context);
    try std.testing.expect(std.mem.indexOf(u8, workspace_text, "workspace=/repo") != null);

    const zls = try workflows.zlsStatusResourceValue(arena.allocator(), context);
    try std.testing.expect(!zls.object.get("running").?.bool);

    const metrics = try workflows.metricsResourceValue(arena.allocator(), context);
    try std.testing.expectEqual(@as(i64, 3), metrics.object.get("command_calls").?.integer);

    const graph = try workflows.importGraphResourceText(arena.allocator(), context);
    try std.testing.expect(std.mem.indexOf(u8, graph, "local.zig") != null);

    try std.testing.expect(std.mem.startsWith(u8, workflows.profilePromptText(), "Use zigar_workspace_info"));
    try std.testing.expect(std.mem.indexOf(u8, workflows.workflowPromptText("zigar_release_workflow"), "release") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflows.workflowPromptText("unknown"), "Discover relevant tests") != null);
    try workspace.verify();
    try scanner.verify();
}

test "runtime UX file command planning and command errors stay behind ports" {
    var commands = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var scanner = fakes.FakeWorkspaceScanner.init(std.testing.allocator);
    defer scanner.deinit();
    var session = fakes.FakeRuntimeSession{};
    defer session.deinit(std.testing.allocator);
    var catalog = fakes.FakeToolCatalog.init("{}");
    const context = testContext(&commands, &workspace, &scanner, &session, &catalog);

    try workspace.expectResolve(.{ .path = "src/main.zig", .provenance = "runtime_ux.run_plan" }, "/repo/src/main.zig");
    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "fmt", "--check", "src/main.zig", "--color", "off" },
        .cwd = "/repo",
        .timeout_ms = 250,
        .provenance = "zigar_job_start",
    }, .{
        .exit_code = 1,
        .term = .{ .exited = 1 },
        .stdout = "",
        .stderr = "format drift\n",
        .duration_ms = 3,
    });
    try workspace.expectResolve(.{ .path = "src/bad.zig", .provenance = "runtime_ux.run_plan" }, "/repo/src/bad.zig");
    try commands.expectRunError(.{
        .argv = &.{ "/bin/zig", "ast-check", "src/bad.zig" },
        .cwd = "/repo",
        .timeout_ms = 300,
        .provenance = "zigar_run_stream",
    }, error.RequestTimeout);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const failed = try workflows.runJobValue(arena.allocator(), context, .{
        .tool_name = "zigar_job_start",
        .command = "fmt-check",
        .file = "src/main.zig",
        .extra_args = &.{ "--color", "off" },
        .timeout_ms = 250,
    });
    try std.testing.expect(!failed.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("format drift\n", failed.object.get("stderr_tail").?.string);

    const command_error = try workflows.runJobValue(arena.allocator(), context, .{
        .tool_name = "zigar_run_stream",
        .command = "check",
        .file = "src/bad.zig",
        .timeout_ms = 300,
        .include_events = true,
    });
    try std.testing.expect(!command_error.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("timeout", command_error.object.get("error_kind").?.string);

    try std.testing.expectError(error.MissingFile, workflows.runJobValue(arena.allocator(), context, .{
        .tool_name = "zigar_job_start",
        .command = "test",
        .timeout_ms = 10,
    }));
    try std.testing.expectError(error.InvalidArguments, workflows.runJobValue(arena.allocator(), context, .{
        .tool_name = "zigar_job_start",
        .command = "unknown",
        .timeout_ms = 10,
    }));

    try commands.verify();
    try workspace.verify();
}
