const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const support = @import("../usecase_support.zig");
const ci_evidence = @import("ci_evidence.zig");
const fakes = @import("../../../testing/fakes/root.zig");

/// Aliases command execution helpers shared by workflow entrypoints.
const command = support.command;

test "CI XML and matrix projections escape command output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const escaped = try ci_evidence.xmlEscape(allocator, "&<>\"'\x01ok");
    try std.testing.expectEqualStrings("&amp;&lt;&gt;&quot;&apos;&#xFFFD;ok", escaped);

    const argv = &.{ "zig", "test", "src/main.zig" };
    const failed = command.RunResult{
        .term = .{ .exited = 1 },
        .stdout = "out <ok>",
        .stderr = "src/main.zig:1:1: error: bad & worse",
        .duration_ms = 17,
    };
    const failed_xml = try ci_evidence.junitXmlForCommand(allocator, argv, failed);
    try std.testing.expect(std.mem.indexOf(u8, failed_xml, "<failure") != null);
    try std.testing.expect(std.mem.indexOf(u8, failed_xml, "&amp; worse") != null);

    const passed = command.RunResult{
        .term = .{ .exited = 0 },
        .stdout = "ok",
        .stderr = "",
        .duration_ms = 3,
    };
    const passed_xml = try ci_evidence.junitXmlForCommand(allocator, argv, passed);
    try std.testing.expect(std.mem.indexOf(u8, passed_xml, "failures=\"0\"") != null);

    const run_entry = (try ci_evidence.matrixRunEntryValue(allocator, "zig", argv, "/repo", 1000, failed)).object;
    try std.testing.expectEqualStrings("zig_matrix_entry", run_entry.get("kind").?.string);
    try std.testing.expect(!run_entry.get("ok").?.bool);

    const error_entry = (try ci_evidence.matrixCommandErrorEntryValue(allocator, "zig-nightly", argv, "/repo", 1000, error.Timeout)).object;
    try std.testing.expectEqualStrings("Timeout", error_entry.get("error").?.string);
    try std.testing.expect(error_entry.get("result") != null);
}

test "CI public workflows run annotations junit and matrix through ports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();
    var workspace_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace_fake.deinit();

    try workspace_fake.expectResolve(.{ .path = "src/main.zig", .provenance = "arch110-workflow-resolve" }, "/repo/src/main.zig");
    try command_fake.expectRun(.{
        .argv = &.{ "zig", "ast-check", "/repo/src/main.zig" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 1,
        .stderr = "src/main.zig:1:1: error: bad\n    ^\n",
        .duration_ms = 8,
    });

    try workspace_fake.expectResolve(.{ .path = "tests/main_test.zig", .provenance = "arch110-workflow-resolve" }, "/repo/tests/main_test.zig");
    try command_fake.expectRun(.{
        .argv = &.{ "zig", "test", "/repo/tests/main_test.zig", "--test-filter", "case", "--summary", "all" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 1,
        .stdout = "FAIL case\n",
        .stderr = "tests/main_test.zig:2:1: error: failed\n",
        .duration_ms = 11,
    });

    try command_fake.expectRun(.{
        .argv = &.{ "zig", "build", "test" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 0,
        .stdout = "ok\n",
        .duration_ms = 5,
    });

    try command_fake.expectRun(.{
        .argv = &.{ "zig-a", "build", "test", "--summary", "all" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 0,
        .stdout = "ok\n",
        .duration_ms = 6,
    });
    try command_fake.expectRun(.{
        .argv = &.{ "zig-b", "build", "test", "--summary", "all" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, .{
        .exit_code = 1,
        .stderr = "src/main.zig:3:1: error: nightly failure\n",
        .duration_ms = 7,
    });
    try command_fake.expectRunError(.{
        .argv = &.{ "zig-c", "build", "test", "--summary", "all" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, error.Timeout);

    var app = ci_evidence.App.init(releaseWorkflowTestContext(command_fake.port(), workspace_fake.port()), allocator);

    const annotations_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"src/main.zig\"}", .{});
    const annotations = try ci_evidence.zigCiAnnotations(&app, allocator, annotations_args.value);
    try std.testing.expectEqualStrings("zig_ci_annotations", annotations.value.object.get("kind").?.string);
    try std.testing.expectEqual(@as(i64, 1), annotations.value.object.get("annotation_count").?.integer);

    const junit_file_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"tests/main_test.zig\",\"filter\":\"case\",\"args\":\"--summary all\"}", .{});
    const junit_file = try ci_evidence.zigJunit(&app, allocator, junit_file_args.value);
    try std.testing.expect(!junit_file.value.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 1), junit_file.value.object.get("failures").?.integer);

    const junit_build = try ci_evidence.zigJunit(&app, allocator, null);
    try std.testing.expect(junit_build.value.object.get("ok").?.bool);

    const matrix_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"zig_paths\":\"zig-a zig-b zig-c\",\"args\":\"--summary all\"}", .{});
    const matrix = try ci_evidence.zigMatrixCheck(&app, allocator, matrix_args.value);
    try std.testing.expect(!matrix.value.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(i64, 1), matrix.value.object.get("passed").?.integer);
    try std.testing.expectEqual(@as(i64, 2), matrix.value.object.get("failed").?.integer);

    try command_fake.verify();
    try workspace_fake.verify();
}

test "CI workflows render command runner errors as structured results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var command_fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_fake.deinit();
    var workspace_fake = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace_fake.deinit();

    try workspace_fake.expectResolve(.{ .path = "src/main.zig", .provenance = "arch110-workflow-resolve" }, "/repo/src/main.zig");
    try command_fake.expectRunError(.{
        .argv = &.{ "zig", "ast-check", "/repo/src/main.zig" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, error.Unavailable);
    try workspace_fake.expectResolve(.{ .path = "tests/main_test.zig", .provenance = "arch110-workflow-resolve" }, "/repo/tests/main_test.zig");
    try command_fake.expectRunError(.{
        .argv = &.{ "zig", "test", "/repo/tests/main_test.zig" },
        .cwd = "/repo",
        .timeout_ms = 1000,
        .max_stdout_bytes = support.command_output_limit,
        .max_stderr_bytes = support.command_output_limit,
        .provenance = "arch110-workflow-command",
    }, error.Timeout);

    var app = ci_evidence.App.init(releaseWorkflowTestContext(command_fake.port(), workspace_fake.port()), allocator);
    const annotations_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"src/main.zig\"}", .{});
    const annotations = try ci_evidence.zigCiAnnotations(&app, allocator, annotations_args.value);
    try std.testing.expect(!annotations.is_error);
    try std.testing.expectEqualStrings("command_error", annotations.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("run_ast_check", annotations.value.object.get("title").?.string);
    try std.testing.expectEqualStrings("Unavailable", annotations.value.object.get("error").?.string);

    const junit_args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"file\":\"tests/main_test.zig\"}", .{});
    const junit = try ci_evidence.zigJunit(&app, allocator, junit_args.value);
    try std.testing.expect(!junit.is_error);
    try std.testing.expectEqualStrings("command_error", junit.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("run_tests", junit.value.object.get("title").?.string);
    try std.testing.expectEqualStrings("Timeout", junit.value.object.get("error").?.string);

    try command_fake.verify();
    try workspace_fake.verify();
}

/// Returns a typed context backed by this fixture or runtime state.
fn releaseWorkflowTestContext(command_runner: ports.CommandRunner, workspace_store: ports.WorkspaceStore) app_context.ReleaseWorkflowContext {
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigar-cache", .transport = "test" },
        .tool_paths = .{ .zig = "zig" },
        .timeouts = .{ .command_ms = 1000, .zls_ms = 1000 },
        .command_runner = command_runner,
        .workspace_store = workspace_store,
        .workspace_scanner = undefined,
        .tool_manifest = undefined,
    };
}
