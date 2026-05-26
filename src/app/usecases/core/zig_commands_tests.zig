const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const zig_commands = @import("zig_commands.zig");
const fake_command = @import("../../../testing/fakes/command_runner.zig");
const fake_workspace = @import("../../../testing/fakes/workspace_store.zig");

/// Returns a typed context backed by this fixture or runtime state.
fn context(command_runner: ports.CommandRunner, workspace_store: ports.WorkspaceStore) app_context.CoreCommandContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .tool_paths = .{ .zig = "/bin/zig", .zls = "/bin/zls" },
        .timeouts = .{ .command_ms = 12_000, .zls_ms = 30_000 },
        .zls_state = .{ .status = "connected" },
        .command_runner = command_runner,
        .workspace_store = workspace_store,
    };
}

test "version use case runs zig and optional zls through command port" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "version" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig version",
    }, .{
        .exit_code = 0,
        .stdout = "0.16.0\n",
        .stderr = "",
    });
    try commands.expectRun(.{
        .argv = &.{ "/bin/zls", "--version" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zls version",
    }, .{
        .exit_code = 0,
        .stdout = "0.16.0\n",
        .stderr = "",
    });

    var outcome = try zig_commands.version(allocator, context(commands.port(), workspace.port()), .{});
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(.ok, std.meta.activeTag(outcome));
    try std.testing.expectEqualStrings("0.16.0\n", outcome.ok.zig.result.stdout);
    try std.testing.expect(outcome.ok.zls != null);
    try std.testing.expectEqualStrings("connected", outcome.ok.zls_status);
    try commands.verify();
    try workspace.verify();
}

test "version use case treats zls command errors as unavailable" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "version" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig version",
    }, .{
        .exit_code = 0,
        .stdout = "0.16.0\n",
        .stderr = "",
    });
    try commands.expectRunError(.{
        .argv = &.{ "/bin/zls", "--version" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zls version",
    }, error.FileNotFound);

    var outcome = try zig_commands.version(allocator, context(commands.port(), workspace.port()), .{});
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(.ok, std.meta.activeTag(outcome));
    try std.testing.expect(outcome.ok.zls == null);
    try commands.verify();
    try workspace.verify();
}

test "build use case constructs exact argv timeout cwd and output limits" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "build", "test", "--summary", "all" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig build",
    }, .{
        .exit_code = 0,
        .stdout = "ok\n",
        .stderr = "",
        .duration_ms = 7,
    });

    var outcome = try zig_commands.build(allocator, context(commands.port(), workspace.port()), .{
        .extra_args = &.{ "test", "--summary", "all" },
    });
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(.ok, std.meta.activeTag(outcome));
    try std.testing.expectEqualStrings("zig build", outcome.ok.title);
    try std.testing.expectEqualStrings("/bin/zig", outcome.ok.argv.items[0]);
    try std.testing.expectEqualStrings("ok\n", outcome.ok.result.stdout);
    try std.testing.expectEqual(@as(i64, 12_000), outcome.ok.timeout_ms);
    try commands.verify();
    try workspace.verify();
}

test "test use case resolves workspace file and appends filter before extra args" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try workspace.expectResolve(.{
        .path = "src/main.zig",
        .provenance = "zig_test source file",
    }, "/workspace/src/main.zig");
    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "test", "/workspace/src/main.zig", "--test-filter", "smoke", "--summary", "all" },
        .cwd = "/workspace",
        .timeout_ms = 30_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig test",
    }, .{
        .exit_code = 0,
        .stdout = "1/1 passed\n",
        .stderr = "",
    });

    var outcome = try zig_commands.testCommand(allocator, context(commands.port(), workspace.port()), .{
        .file = "src/main.zig",
        .filter = "smoke",
        .extra_args = &.{ "--summary", "all" },
        .timeout_ms = 30_000,
    });
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(.ok, std.meta.activeTag(outcome));
    try std.testing.expectEqualStrings("/workspace/src/main.zig", outcome.ok.argv.items[2]);
    try commands.verify();
    try workspace.verify();
}

test "test use case runs workspace test suite when no file is supplied" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "build", "test", "--summary", "all" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig test",
    }, .{ .exit_code = 0, .stdout = "ok\n" });

    var outcome = try zig_commands.testCommand(allocator, context(commands.port(), workspace.port()), .{
        .extra_args = &.{ "--summary", "all" },
    });
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(.ok, std.meta.activeTag(outcome));
    try std.testing.expectEqualStrings("build", outcome.ok.argv.items[1]);
    try commands.verify();
    try workspace.verify();
}

test "test and translate-c report workspace path failures before running" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try workspace.expectResolveError(.{
        .path = "",
        .provenance = "zig_test source file",
    }, error.EmptyPath);
    try workspace.expectResolveError(.{
        .path = "../ffi.h",
        .provenance = "zig_translate_c source file",
    }, error.PathOutsideWorkspace);

    var test_outcome = try zig_commands.testCommand(allocator, context(commands.port(), workspace.port()), .{ .file = "" });
    defer test_outcome.deinit(allocator);
    try std.testing.expectEqual(.err, std.meta.activeTag(test_outcome));
    try std.testing.expectEqual(.workspace_path, std.meta.activeTag(test_outcome.err));
    try std.testing.expectEqual(error.EmptyPath, test_outcome.err.workspace_path.err);

    var translate_outcome = try zig_commands.translateC(allocator, context(commands.port(), workspace.port()), .{ .file = "../ffi.h" });
    defer translate_outcome.deinit(allocator);
    try std.testing.expectEqual(.err, std.meta.activeTag(translate_outcome));
    try std.testing.expectEqual(.workspace_path, std.meta.activeTag(translate_outcome.err));
    try std.testing.expectEqual(error.PathOutsideWorkspace, translate_outcome.err.workspace_path.err);

    try commands.verify();
    try workspace.verify();
}

test "check use case reports workspace path failures before command execution" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try workspace.expectResolveError(.{
        .path = "../outside.zig",
        .provenance = "zig_check source file",
    }, error.PathOutsideWorkspace);

    var outcome = try zig_commands.check(allocator, context(commands.port(), workspace.port()), .{
        .file = "../outside.zig",
    });
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(.err, std.meta.activeTag(outcome));
    try std.testing.expectEqual(.workspace_path, std.meta.activeTag(outcome.err));
    try std.testing.expectEqual(error.PathOutsideWorkspace, outcome.err.workspace_path.err);
    try std.testing.expectEqualStrings("../outside.zig", outcome.err.workspace_path.path);
    try commands.verify();
    try workspace.verify();
}

test "check and translate-c construct resolved file commands" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try workspace.expectResolve(.{
        .path = "src/main.zig",
        .provenance = "zig_check source file",
    }, "/workspace/src/main.zig");
    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "ast-check", "/workspace/src/main.zig" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig ast-check",
    }, .{ .exit_code = 0, .stdout = "ok\n" });

    try workspace.expectResolve(.{
        .path = "include/foo.h",
        .provenance = "zig_translate_c source file",
    }, "/workspace/include/foo.h");
    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "translate-c", "/workspace/include/foo.h", "-Iinclude" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig translate-c",
    }, .{ .exit_code = 0, .stdout = "const c = @cImport({});\n" });

    var check_outcome = try zig_commands.check(allocator, context(commands.port(), workspace.port()), .{ .file = "src/main.zig" });
    defer check_outcome.deinit(allocator);
    try std.testing.expectEqual(.ok, std.meta.activeTag(check_outcome));
    try std.testing.expectEqualStrings("ast-check", check_outcome.ok.argv.items[1]);

    var translate_outcome = try zig_commands.translateC(allocator, context(commands.port(), workspace.port()), .{
        .file = "include/foo.h",
        .extra_args = &.{"-Iinclude"},
    });
    defer translate_outcome.deinit(allocator);
    try std.testing.expectEqual(.ok, std.meta.activeTag(translate_outcome));
    try std.testing.expectEqualStrings("translate-c", translate_outcome.ok.argv.items[1]);

    try commands.verify();
    try workspace.verify();
}

test "command runner errors preserve argv and normalized timeout in typed failure" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRunError(.{
        .argv = &.{ "/bin/zig", "build" },
        .cwd = "/workspace",
        .timeout_ms = 1,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig build",
    }, error.Timeout);

    var outcome = try zig_commands.build(allocator, context(commands.port(), workspace.port()), .{ .timeout_ms = 0 });
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(.err, std.meta.activeTag(outcome));
    try std.testing.expectEqual(.command_run, std.meta.activeTag(outcome.err));
    try std.testing.expectEqual(error.Timeout, outcome.err.command_run.err);
    try std.testing.expectEqualStrings("/bin/zig", outcome.err.command_run.argv.items[0]);
    try std.testing.expectEqual(@as(i64, 1), outcome.err.command_run.timeout_ms);
    try std.testing.expectEqual(zig_commands.command_output_limit, outcome.err.command_run.stdout_limit);
    try commands.verify();
    try workspace.verify();
}

test "explain command covers focused modes and workspace failures" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try workspace.expectResolve(.{ .path = "src/main.zig", .provenance = "core explain source file" }, "/workspace/src/main.zig");
    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "ast-check", "/workspace/src/main.zig" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig explain check",
    }, .{ .exit_code = 0 });

    try workspace.expectResolve(.{ .path = "src/test.zig", .provenance = "core explain test file" }, "/workspace/src/test.zig");
    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "test", "/workspace/src/test.zig" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig explain test file",
    }, .{ .exit_code = 0 });

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "build", "test" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig explain test suite",
    }, .{ .exit_code = 0 });

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "build" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig explain build",
    }, .{ .exit_code = 0 });

    try workspace.expectResolve(.{ .path = ".", .provenance = "core explain format target" }, "/workspace");
    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "fmt", "--check", "/workspace" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig explain fmt",
    }, .{ .exit_code = 0 });

    try workspace.expectResolveError(.{ .path = "../outside.zig", .provenance = "core explain source file" }, error.PathOutsideWorkspace);
    try workspace.expectResolveError(.{ .path = "../test.zig", .provenance = "core explain test file" }, error.PathOutsideWorkspace);
    try workspace.expectResolveError(.{ .path = "../fmt", .provenance = "core explain format target" }, error.PathOutsideWorkspace);

    var check_outcome = try zig_commands.explainCommand(allocator, context(commands.port(), workspace.port()), .{
        .command = "check",
        .file = "src/main.zig",
    }, "zig explain check");
    defer check_outcome.deinit(allocator);
    try std.testing.expectEqual(.ok, std.meta.activeTag(check_outcome));
    try std.testing.expectEqualStrings("check", check_outcome.ok.mode);

    var test_file_outcome = try zig_commands.explainCommand(allocator, context(commands.port(), workspace.port()), .{
        .command = "test",
        .file = "src/test.zig",
    }, "zig explain test file");
    defer test_file_outcome.deinit(allocator);
    try std.testing.expectEqual(.ok, std.meta.activeTag(test_file_outcome));
    try std.testing.expectEqualStrings("test", test_file_outcome.ok.mode);

    var test_suite_outcome = try zig_commands.explainCommand(allocator, context(commands.port(), workspace.port()), .{
        .command = "test",
    }, "zig explain test suite");
    defer test_suite_outcome.deinit(allocator);
    try std.testing.expectEqual(.ok, std.meta.activeTag(test_suite_outcome));
    try std.testing.expectEqualStrings("test", test_suite_outcome.ok.mode);

    var build_outcome = try zig_commands.explainCommand(allocator, context(commands.port(), workspace.port()), .{
        .command = "build",
    }, "zig explain build");
    defer build_outcome.deinit(allocator);
    try std.testing.expectEqual(.ok, std.meta.activeTag(build_outcome));
    try std.testing.expectEqualStrings("build", build_outcome.ok.mode);

    var fmt_outcome = try zig_commands.explainCommand(allocator, context(commands.port(), workspace.port()), .{
        .command = "fmt-check",
    }, "zig explain fmt");
    defer fmt_outcome.deinit(allocator);
    try std.testing.expectEqual(.ok, std.meta.activeTag(fmt_outcome));
    try std.testing.expectEqualStrings("fmt-check", fmt_outcome.ok.mode);

    var check_fail = try zig_commands.explainCommand(allocator, context(commands.port(), workspace.port()), .{
        .command = "check",
        .file = "../outside.zig",
    }, "zig explain check fail");
    defer check_fail.deinit(allocator);
    try std.testing.expectEqual(.err, std.meta.activeTag(check_fail));
    try std.testing.expectEqual(.workspace_path, std.meta.activeTag(check_fail.err));
    try std.testing.expectEqual(error.PathOutsideWorkspace, check_fail.err.workspace_path.err);

    var test_fail = try zig_commands.explainCommand(allocator, context(commands.port(), workspace.port()), .{
        .command = "test",
        .file = "../test.zig",
    }, "zig explain test fail");
    defer test_fail.deinit(allocator);
    try std.testing.expectEqual(.err, std.meta.activeTag(test_fail));
    try std.testing.expectEqual(.workspace_path, std.meta.activeTag(test_fail.err));
    try std.testing.expectEqual(error.PathOutsideWorkspace, test_fail.err.workspace_path.err);

    var fmt_fail = try zig_commands.explainCommand(allocator, context(commands.port(), workspace.port()), .{
        .command = "fmt-check",
        .file = "../fmt",
    }, "zig explain fmt fail");
    defer fmt_fail.deinit(allocator);
    try std.testing.expectEqual(.err, std.meta.activeTag(fmt_fail));
    try std.testing.expectEqual(.workspace_path, std.meta.activeTag(fmt_fail.err));
    try std.testing.expectEqual(error.PathOutsideWorkspace, fmt_fail.err.workspace_path.err);

    try commands.verify();
    try workspace.verify();
}

test "explain command requires file for explicit check mode" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    var outcome = try zig_commands.explainCommand(allocator, context(commands.port(), workspace.port()), .{
        .command = "check",
    }, "zig explain errors");
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(.err, std.meta.activeTag(outcome));
    try std.testing.expectEqual(.argument, std.meta.activeTag(outcome.err));
    try std.testing.expectEqualStrings("file", outcome.err.argument.field.?);
    try commands.verify();
    try workspace.verify();
}

test "explain command frees owned mode when later allocation fails" {
    var commands = fake_command.FakeCommandRunner.init(std.testing.allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();

    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        const allocator = failing.allocator();

        var outcome = zig_commands.explainCommand(allocator, context(commands.port(), workspace.port()), .{
            .command = "build-test",
        }, "zig explain oom") catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        outcome.deinit(allocator);
    }
}

test "explain command use case owns focused command mode construction" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try commands.expectRun(.{
        .argv = &.{ "/bin/zig", "build", "test" },
        .cwd = "/workspace",
        .timeout_ms = 12_000,
        .max_stdout_bytes = zig_commands.command_output_limit,
        .max_stderr_bytes = zig_commands.command_output_limit,
        .provenance = "zig explain errors",
    }, .{
        .exit_code = 1,
        .stderr = "src/main.zig:1:1: error: expected type\n",
    });

    var outcome = try zig_commands.explainCommand(allocator, context(commands.port(), workspace.port()), .{}, "zig explain errors");
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(.ok, std.meta.activeTag(outcome));
    try std.testing.expectEqualStrings("build-test", outcome.ok.mode);
    try std.testing.expect(outcome.ok.command.result.effectiveTerm().failed());
    try commands.verify();
    try workspace.verify();
}

test "explain command rejects unsupported command mode without running" {
    const allocator = std.testing.allocator;
    var commands = fake_command.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    var outcome = try zig_commands.explainCommand(allocator, context(commands.port(), workspace.port()), .{
        .command = "run",
    }, "zig explain errors");
    defer outcome.deinit(allocator);

    try std.testing.expectEqual(.err, std.meta.activeTag(outcome));
    try std.testing.expectEqual(.argument, std.meta.activeTag(outcome.err));
    try std.testing.expectEqualStrings("command", outcome.err.argument.field.?);
    try std.testing.expectEqualStrings("run", outcome.err.argument.actual.?);
    try commands.verify();
    try workspace.verify();
}
