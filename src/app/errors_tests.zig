const std = @import("std");

const errors = @import("errors.zig");

test "app error captures argument metadata without transport result types" {
    const err = errors.invalidArgument("mode", "compact, standard, or deep", "verbose", "Choose a supported mode.");
    try std.testing.expectEqual(errors.Category.argument, err.category);
    try std.testing.expectEqualStrings("argument", err.category.name());
    try std.testing.expectEqualStrings("parse_request", err.operation);
    try std.testing.expectEqualStrings("validate_argument", err.phase);
    try std.testing.expectEqualStrings("invalid_argument", err.code);
    try std.testing.expectEqualStrings("mode", err.field.?);
    try std.testing.expectEqualStrings("verbose", err.actual.?);
    try std.testing.expect(!err.ownsMemory());
}

test "app error categories cover workspace backend and tool failures" {
    const workspace = errors.workspacePathRejected("../outside.zig", "/repo", "path_outside_workspace", "PathOutsideWorkspace", "Use a workspace-relative path.");
    try std.testing.expectEqual(errors.Category.workspace_path, workspace.category);
    try std.testing.expectEqualStrings("../outside.zig", workspace.path.?);
    try std.testing.expectEqualStrings("/repo", workspace.workspace.?);

    const backend = errors.backendUnavailable("zflame", "FileNotFound", "Install zflame or configure the backend path.");
    try std.testing.expectEqual(errors.Category.backend, backend.category);
    try std.testing.expect(backend.retryable);
    try std.testing.expectEqualStrings("zflame", backend.backend.?);

    const failed = errors.toolFailure("profile_plan", "build_plan", "plan_failed", "InvalidInput", "Retry with a valid profiling request.");
    try std.testing.expectEqual(errors.Category.tool, failed.category);
    try std.testing.expectEqualStrings("profile_plan", failed.operation);
}

test "generic app result carries typed data or typed error" {
    const TypedResult = errors.Result(i64);

    const ok: TypedResult = .{ .ok = 42 };
    try std.testing.expect(ok.isOk());

    const failed: TypedResult = .{ .err = errors.missingArgument("command", "non-empty command argv") };
    try std.testing.expect(failed.isErr());
    try std.testing.expectEqual(errors.Category.argument, failed.err.category);
    try std.testing.expectEqualStrings("missing_required_argument", failed.err.code);
}
