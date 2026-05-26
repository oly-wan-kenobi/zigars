const std = @import("std");

const app_context = @import("../../context.zig");
const flamegraph = @import("flamegraph.zig");
const fakes = @import("../../../testing/fakes/root.zig");

const svg = "<svg xmlns=\"http://www.w3.org/2000/svg\"><title>fixture</title></svg>\n";

fn testContext(command_runner: anytype, workspace_store: anytype) app_context.ProfilingContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigar-cache" },
        .tool_paths = .{ .zflame = "/bin/zflame" },
        .timeouts = .{ .command_ms = 5000 },
        .command_runner = command_runner.port(),
        .workspace_store = workspace_store.port(),
    };
}

fn request() flamegraph.Request {
    return .{
        .input = "stacks.folded",
        .input_abs = "/workspace/stacks.folded",
        .output = "profile.svg",
        .output_abs = "/workspace/profile.svg",
        .format = .recursive,
        .options = .{
            .title = "fixture",
            .subtitle = "unit",
            .colors = "hot",
            .width = 1200,
            .min_width = 5,
            .hash = true,
        },
    };
}

fn expectedArgv() []const []const u8 {
    return &.{ "/bin/zflame", "recursive", "--title=fixture", "--subtitle=unit", "--colors=hot", "--width=1200", "--min-width=5", "--hash", "/workspace/stacks.folded" };
}

fn expectedCommandRequest() @import("../../ports.zig").CommandRequest {
    return .{
        .argv = expectedArgv(),
        .cwd = "/workspace",
        .timeout_ms = 5000,
        .max_stdout_bytes = flamegraph.command_output_limit,
        .max_stderr_bytes = flamegraph.command_output_limit,
        .provenance = "zig_flamegraph zflame render",
    };
}

test "flamegraph use case renders svg through command and workspace ports" {
    const allocator = std.testing.allocator;
    var commands = fakes.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try workspace.expectRead(.{
        .path = "stacks.folded",
        .max_bytes = 0,
        .provenance = "zig_flamegraph input readability",
    }, "");
    try commands.expectRun(expectedCommandRequest(), .{
        .exit_code = 0,
        .stdout = svg,
        .stderr = "",
        .duration_ms = 12,
    });
    try workspace.expectWrite(.{
        .path = "profile.svg",
        .bytes = svg,
        .create_parent_dirs = true,
        .replace_existing = true,
        .provenance = "zig_flamegraph SVG artifact",
    }, .{ .bytes_written = svg.len });

    var result = try flamegraph.run(allocator, testContext(&commands, &workspace), request());
    defer result.deinit(allocator);

    const artifact = result.ok;
    try std.testing.expectEqualStrings("zflame", artifact.backend);
    try std.testing.expectEqualStrings("/bin/zflame", artifact.backend_executable_path);
    try std.testing.expectEqualStrings("rendered_ok", artifact.compatibility_status);
    try std.testing.expectEqual(svg.len, artifact.bytes);
    try std.testing.expectEqual(@as(usize, 64), artifact.sha256.len);
    try std.testing.expectEqual(expectedArgv().len, artifact.argv.items.len);
    try std.testing.expectEqualStrings("--hash", artifact.argv.items[7]);
    try std.testing.expectEqual(@as(usize, 1), commands.calls().len);
    try commands.verify();
    try workspace.verify();
}

test "flamegraph use case rejects missing input and output before ports" {
    const allocator = std.testing.allocator;
    var commands = fakes.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    var missing_input = request();
    missing_input.input = "";
    var input_result = try flamegraph.run(allocator, testContext(&commands, &workspace), missing_input);
    defer input_result.deinit(allocator);
    const input_failure = input_result.err.workspace_input_read_failed;
    try std.testing.expectEqual(error.InvalidRequest, input_failure.err);
    try std.testing.expectEqualStrings("input", input_failure.error_info.field.?);

    var missing_output = request();
    missing_output.output = "";
    var output_result = try flamegraph.run(allocator, testContext(&commands, &workspace), missing_output);
    defer output_result.deinit(allocator);
    const output_failure = output_result.err.workspace_artifact_write_failed;
    try std.testing.expectEqual(error.InvalidRequest, output_failure.err);
    try std.testing.expectEqualStrings("output", output_failure.error_info.field.?);
    try commands.verify();
    try workspace.verify();
}

test "flamegraph use case rejects non-svg backend output before write" {
    const allocator = std.testing.allocator;
    var commands = fakes.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try workspace.expectRead(.{ .path = "stacks.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, "");
    try commands.expectRun(expectedCommandRequest(), .{ .exit_code = 0, .stdout = "main;not-svg 1\n" });

    var result = try flamegraph.run(allocator, testContext(&commands, &workspace), request());
    defer result.deinit(allocator);

    const failure = result.err.backend_output_malformed;
    try std.testing.expectEqualStrings("backend_output_malformed", failure.error_info.code);
    try std.testing.expectEqualStrings("validate_svg", failure.error_info.phase);
    try std.testing.expectEqualStrings("zflame", failure.backend);
    try commands.verify();
    try workspace.verify();
}

test "flamegraph use case reports nonzero zflame command result" {
    const allocator = std.testing.allocator;
    var commands = fakes.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try workspace.expectRead(.{ .path = "stacks.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, "");
    try commands.expectRun(expectedCommandRequest(), .{
        .exit_code = 7,
        .stdout = "partial",
        .stderr = "bad format",
        .stderr_truncated = true,
    });

    var result = try flamegraph.run(allocator, testContext(&commands, &workspace), request());
    defer result.deinit(allocator);

    const failure = result.err.command_failed;
    try std.testing.expectEqualStrings("zflame_command_failed", failure.error_info.code);
    try std.testing.expectEqual(@as(i32, 7), failure.exit_code);
    try std.testing.expectEqualStrings("exited", failure.term.name());
    try std.testing.expectEqual(@as(?i64, 7), failure.term.exitCode());
    try std.testing.expectEqualStrings("partial", failure.stdout);
    try std.testing.expectEqualStrings("bad format", failure.stderr);
    try std.testing.expect(failure.stderr_truncated);
    try std.testing.expectEqualStrings("/bin/zflame", failure.argv.items[0]);
    try commands.verify();
    try workspace.verify();
}

test "flamegraph use case preserves non-exited zflame command terms" {
    const allocator = std.testing.allocator;
    var commands = fakes.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try workspace.expectRead(.{ .path = "stacks.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, "");
    try commands.expectRun(expectedCommandRequest(), .{
        .exit_code = -1,
        .term = .signal,
        .stdout = "partial",
        .stderr = "terminated",
    });

    var result = try flamegraph.run(allocator, testContext(&commands, &workspace), request());
    defer result.deinit(allocator);

    const failure = result.err.command_failed;
    try std.testing.expectEqualStrings("zflame_command_failed", failure.error_info.code);
    try std.testing.expectEqual(@as(i32, -1), failure.exit_code);
    try std.testing.expectEqualStrings("signal", failure.term.name());
    try std.testing.expectEqual(@as(?i64, null), failure.term.exitCode());
    try std.testing.expectEqualStrings("partial", failure.stdout);
    try std.testing.expectEqualStrings("terminated", failure.stderr);
    try commands.verify();
    try workspace.verify();
}

test "flamegraph use case reports backend run port errors" {
    const allocator = std.testing.allocator;
    var commands = fakes.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try workspace.expectRead(.{ .path = "stacks.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, "");
    try commands.expectRunError(expectedCommandRequest(), error.FileNotFound);

    var result = try flamegraph.run(allocator, testContext(&commands, &workspace), request());
    defer result.deinit(allocator);

    const failure = result.err.backend_run_failed;
    try std.testing.expectEqual(error.FileNotFound, failure.err);
    try std.testing.expectEqualStrings("zflame_backend_failed", failure.error_info.code);
    try std.testing.expectEqualStrings("run_zflame", failure.error_info.phase);
    try std.testing.expectEqualStrings("/workspace", failure.cwd);
    try commands.verify();
    try workspace.verify();
}

test "flamegraph use case stops on workspace input read failure" {
    const allocator = std.testing.allocator;
    var commands = fakes.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try workspace.expectReadError(.{
        .path = "stacks.folded",
        .max_bytes = 0,
        .provenance = "zig_flamegraph input readability",
    }, error.FileNotFound);

    var result = try flamegraph.run(allocator, testContext(&commands, &workspace), request());
    defer result.deinit(allocator);

    const failure = result.err.workspace_input_read_failed;
    try std.testing.expectEqual(error.FileNotFound, failure.err);
    try std.testing.expectEqualStrings("workspace_input_read_failed", failure.error_info.code);
    try std.testing.expectEqualStrings("stacks.folded", failure.path);
    try commands.verify();
    try workspace.verify();
}

test "flamegraph use case reports workspace artifact write failure" {
    const allocator = std.testing.allocator;
    var commands = fakes.FakeCommandRunner.init(allocator);
    defer commands.deinit();
    var workspace = fakes.FakeWorkspaceStore.init(allocator);
    defer workspace.deinit();

    try workspace.expectRead(.{ .path = "stacks.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, "");
    try commands.expectRun(expectedCommandRequest(), .{ .exit_code = 0, .stdout = svg });
    try workspace.expectWriteError(.{
        .path = "profile.svg",
        .bytes = svg,
        .create_parent_dirs = true,
        .replace_existing = true,
        .provenance = "zig_flamegraph SVG artifact",
    }, error.AccessDenied);

    var result = try flamegraph.run(allocator, testContext(&commands, &workspace), request());
    defer result.deinit(allocator);

    const failure = result.err.workspace_artifact_write_failed;
    try std.testing.expectEqual(error.AccessDenied, failure.err);
    try std.testing.expectEqualStrings("workspace_artifact_write_failed", failure.error_info.code);
    try std.testing.expectEqualStrings("/workspace/profile.svg", failure.abs_path);
    try commands.verify();
    try workspace.verify();
}
