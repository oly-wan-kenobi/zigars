const std = @import("std");

const app_context = @import("../../context.zig");
const flamegraph = @import("flamegraph.zig");
const flamegraph_diff = @import("flamegraph_diff.zig");
const fake_command = @import("../../../testing/fakes/command_runner.zig");
const fake_workspace = @import("../../../testing/fakes/workspace_store.zig");

test "flamegraph diff run reports late input parent and render failures" {
    const allocator = std.testing.allocator;

    {
        var commands = fake_command.FakeCommandRunner.init(allocator);
        defer commands.deinit();
        var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try workspace.expectResolve(.{ .path = "before.folded", .provenance = "profiling input path resolution" }, "/workspace/before.folded");
        try workspace.expectResolve(.{ .path = "after.folded", .provenance = "profiling input path resolution" }, "/workspace/after.folded");
        try workspace.expectResolve(.{ .path = "diff.svg", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/diff.svg");
        try workspace.expectResolve(.{ .path = "diff.folded", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/diff.folded");
        try workspace.expectRead(.{ .path = "before.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try workspace.expectReadError(.{ .path = "after.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, error.AccessDenied);
        var result = try flamegraph_diff.run(allocator, context, .{ .before = "before.folded", .after = "after.folded", .output = "diff.svg", .intermediate = "diff.folded" });
        defer result.deinit(allocator);
        try std.testing.expectEqual(.err, std.meta.activeTag(result));
        try std.testing.expectEqual(.workspace_input_read_failed, std.meta.activeTag(result.err.failure));
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fake_command.FakeCommandRunner.init(allocator);
        defer commands.deinit();
        var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try workspace.expectResolve(.{ .path = "before.folded", .provenance = "profiling input path resolution" }, "/workspace/before.folded");
        try workspace.expectResolve(.{ .path = "after.folded", .provenance = "profiling input path resolution" }, "/workspace/after.folded");
        try workspace.expectResolve(.{ .path = "diff.svg", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/diff.svg");
        try workspace.expectResolve(.{ .path = "cache/diff.folded", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/cache/diff.folded");
        try workspace.expectRead(.{ .path = "before.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try workspace.expectRead(.{ .path = "after.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try workspace.expectEnsureDirError(.{ .path = "cache", .provenance = "zig_flamegraph_diff intermediate parent" }, error.AccessDenied);
        var result = try flamegraph_diff.run(allocator, context, .{ .before = "before.folded", .after = "after.folded", .output = "diff.svg", .intermediate = "cache/diff.folded" });
        defer result.deinit(allocator);
        try std.testing.expectEqual(.err, std.meta.activeTag(result));
        try std.testing.expectEqual(.workspace_parent_prepare_failed, std.meta.activeTag(result.err.failure));
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fake_command.FakeCommandRunner.init(allocator);
        defer commands.deinit();
        var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
        defer workspace.deinit();
        const context = testProfilingContext(&commands, &workspace);

        try workspace.expectResolve(.{ .path = "before.folded", .provenance = "profiling input path resolution" }, "/workspace/before.folded");
        try workspace.expectResolve(.{ .path = "after.folded", .provenance = "profiling input path resolution" }, "/workspace/after.folded");
        try workspace.expectResolve(.{ .path = "diff.svg", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/diff.svg");
        try workspace.expectResolve(.{ .path = "cache/diff.folded", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/cache/diff.folded");
        try workspace.expectRead(.{ .path = "before.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try workspace.expectRead(.{ .path = "after.folded", .max_bytes = 0, .provenance = "zig_flamegraph_diff input readability" }, "");
        try workspace.expectEnsureDir(.{ .path = "cache", .provenance = "zig_flamegraph_diff intermediate parent" }, .{});
        try commands.expectRun(.{
            .argv = &.{ "/bin/diff-folded", "--output=/workspace/cache/diff.folded", "/workspace/before.folded", "/workspace/after.folded" },
            .cwd = "/workspace",
            .timeout_ms = 5000,
            .max_stdout_bytes = flamegraph_diff.command_output_limit,
            .max_stderr_bytes = flamegraph_diff.command_output_limit,
            .provenance = "zig_flamegraph_diff diff-folded render",
        }, .{ .stdout = "diff ok\n" });
        try workspace.expectRead(.{ .path = "cache/diff.folded", .max_bytes = flamegraph_diff.command_output_limit, .provenance = "zig_flamegraph_diff intermediate folded diff" }, "main;before 1\nmain;after 2\n");
        try workspace.expectRead(.{ .path = "cache/diff.folded", .max_bytes = 0, .provenance = "zig_flamegraph input readability" }, "");
        try commands.expectRun(.{
            .argv = &.{ "/bin/zflame", "recursive", "/workspace/cache/diff.folded" },
            .cwd = "/workspace",
            .timeout_ms = 5000,
            .max_stdout_bytes = flamegraph.command_output_limit,
            .max_stderr_bytes = flamegraph.command_output_limit,
            .provenance = "zig_flamegraph zflame render",
        }, .{ .stdout = "not svg\n" });
        var result = try flamegraph_diff.run(allocator, context, .{ .before = "before.folded", .after = "after.folded", .output = "diff.svg", .intermediate = "cache/diff.folded" });
        defer result.deinit(allocator);
        try std.testing.expectEqual(.err, std.meta.activeTag(result));
        try std.testing.expectEqual(.render_failed, std.meta.activeTag(result.err.failure));
        try commands.verify();
        try workspace.verify();
    }
}

/// Implements test profiling context workflow logic using caller-owned inputs.
fn testProfilingContext(
    commands: *fake_command.FakeCommandRunner,
    workspace: *fake_workspace.FakeWorkspaceStore,
) app_context.ProfilingContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .tool_paths = .{ .zflame = "/bin/zflame", .diff_folded = "/bin/diff-folded" },
        .timeouts = .{ .command_ms = 5000 },
        .command_runner = commands.port(),
        .workspace_store = workspace.port(),
        .clock_and_ids = null,
    };
}
