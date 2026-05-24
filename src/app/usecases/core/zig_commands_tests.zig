const std = @import("std");

const app_context = @import("../../context.zig");
const ports = @import("../../ports.zig");
const zig_commands = @import("zig_commands.zig");
const fake_command = @import("../../../testing/fakes/command_runner.zig");
const fake_workspace = @import("../../../testing/fakes/workspace_store.zig");

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

    switch (outcome) {
        .ok => |*version_result| {
            try std.testing.expectEqualStrings("0.16.0\n", version_result.zig.result.stdout);
            try std.testing.expect(version_result.zls != null);
            try std.testing.expectEqualStrings("connected", version_result.zls_status);
        },
        .err => return error.TestUnexpectedResult,
    }
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

    switch (outcome) {
        .ok => |*version_result| try std.testing.expect(version_result.zls == null),
        .err => return error.TestUnexpectedResult,
    }
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

    switch (outcome) {
        .ok => |*run| {
            try std.testing.expectEqualStrings("zig build", run.title);
            try std.testing.expectEqualStrings("/bin/zig", run.argv.items[0]);
            try std.testing.expectEqualStrings("ok\n", run.result.stdout);
            try std.testing.expectEqual(@as(i64, 12_000), run.timeout_ms);
        },
        .err => return error.TestUnexpectedResult,
    }
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

    switch (outcome) {
        .ok => |*run| try std.testing.expectEqualStrings("/workspace/src/main.zig", run.argv.items[2]),
        .err => return error.TestUnexpectedResult,
    }
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

    switch (outcome) {
        .err => |*failure| switch (failure.*) {
            .workspace_path => |workspace_failure| {
                try std.testing.expectEqual(error.PathOutsideWorkspace, workspace_failure.err);
                try std.testing.expectEqualStrings("../outside.zig", workspace_failure.path);
            },
            else => return error.TestUnexpectedResult,
        },
        .ok => return error.TestUnexpectedResult,
    }
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

    switch (outcome) {
        .err => |*failure| switch (failure.*) {
            .command_run => |command_failure| {
                try std.testing.expectEqual(error.Timeout, command_failure.err);
                try std.testing.expectEqualStrings("/bin/zig", command_failure.argv.items[0]);
                try std.testing.expectEqual(@as(i64, 1), command_failure.timeout_ms);
                try std.testing.expectEqual(zig_commands.command_output_limit, command_failure.stdout_limit);
            },
            else => return error.TestUnexpectedResult,
        },
        .ok => return error.TestUnexpectedResult,
    }
    try commands.verify();
    try workspace.verify();
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

    switch (outcome) {
        .ok => |*run| {
            try std.testing.expectEqualStrings("build-test", run.mode);
            try std.testing.expect(run.command.result.effectiveTerm().failed());
        },
        .err => return error.TestUnexpectedResult,
    }
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

    switch (outcome) {
        .err => |*failure| switch (failure.*) {
            .argument => |arg| {
                try std.testing.expectEqualStrings("command", arg.field.?);
                try std.testing.expectEqualStrings("run", arg.actual.?);
            },
            else => return error.TestUnexpectedResult,
        },
        .ok => return error.TestUnexpectedResult,
    }
    try commands.verify();
    try workspace.verify();
}
