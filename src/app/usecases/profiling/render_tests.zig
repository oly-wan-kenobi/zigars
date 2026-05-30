//! Pins the render facade's path-resolution boundary: input-resolution failures abort
//! before the backend, and a later output-resolution failure still frees the
//! already-resolved input path (no leak). `for_output` flags which side failed.
const std = @import("std");

const app_context = @import("../../context.zig");
const render = @import("render.zig");
const fakes = @import("../../../testing/fakes/root.zig");

test "profiling render reports input path resolution failures" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var command_runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_runner.deinit();
    try workspace.expectResolveError(.{
        .path = "missing.folded",
        .for_output = false,
        .provenance = "profiling input path resolution",
    }, error.FileNotFound);

    var result = try render.run(std.testing.allocator, profilingContext(&workspace, &command_runner), .{
        .input = "missing.folded",
        .output = "out.svg",
        .format = .recursive,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(error.FileNotFound, result.err.workspace_path_failed.err);
    try std.testing.expect(!result.err.workspace_path_failed.for_output);
    try workspace.verify();
    try command_runner.verify();
}

test "profiling render frees input path when output resolution fails" {
    var workspace = fakes.FakeWorkspaceStore.init(std.testing.allocator);
    defer workspace.deinit();
    var command_runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_runner.deinit();
    try workspace.expectResolve(.{
        .path = "in.folded",
        .for_output = false,
        .provenance = "profiling input path resolution",
    }, "/repo/in.folded");
    try workspace.expectResolveError(.{
        .path = "outside/out.svg",
        .for_output = true,
        .provenance = "profiling output path resolution",
    }, error.PathOutsideWorkspace);

    var result = try render.run(std.testing.allocator, profilingContext(&workspace, &command_runner), .{
        .input = "in.folded",
        .output = "outside/out.svg",
        .format = .recursive,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(error.PathOutsideWorkspace, result.err.workspace_path_failed.err);
    try std.testing.expect(result.err.workspace_path_failed.for_output);
    try workspace.verify();
    try command_runner.verify();
}

/// Implements profiling context workflow logic using caller-owned inputs.
fn profilingContext(workspace: *fakes.FakeWorkspaceStore, command_runner: *fakes.FakeCommandRunner) app_context.ProfilingContext {
    // Keep this logic centralized so callers observe one consistent behavior path.
    return .{
        .workspace = .{ .root = "/repo", .cache_root = "/repo/.zigars-cache" },
        .tool_paths = .{},
        .timeouts = .{},
        .command_runner = command_runner.port(),
        .workspace_store = workspace.port(),
    };
}
