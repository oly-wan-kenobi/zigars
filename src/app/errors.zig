const std = @import("std");

pub const Category = enum {
    argument,
    workspace_path,
    backend,
    tool,

    pub fn name(self: Category) []const u8 {
        return @tagName(self);
    }
};

pub const Detail = struct {
    key: []const u8,
    value: []const u8,
};

pub const AppError = struct {
    category: Category,
    operation: []const u8,
    phase: []const u8,
    code: []const u8,
    retryable: bool = false,
    field: ?[]const u8 = null,
    expected: ?[]const u8 = null,
    actual: ?[]const u8 = null,
    path: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    backend: ?[]const u8 = null,
    cause: ?[]const u8 = null,
    resolution: []const u8,
    details: []const Detail = &.{},

    /// AppError borrows all slice fields. Renderers that need a longer-lived
    /// payload must copy those fields into their own allocator-owned result.
    pub fn ownsMemory(_: AppError) bool {
        return false;
    }
};

pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: AppError,

        const Self = @This();

        pub fn isOk(self: Self) bool {
            return switch (self) {
                .ok => true,
                .err => false,
            };
        }

        pub fn isErr(self: Self) bool {
            return !self.isOk();
        }
    };
}

pub fn invalidArgument(field: []const u8, expected: []const u8, actual: []const u8, resolution: []const u8) AppError {
    return .{
        .category = .argument,
        .operation = "parse_request",
        .phase = "validate_argument",
        .code = "invalid_argument",
        .field = field,
        .expected = expected,
        .actual = actual,
        .resolution = resolution,
    };
}

pub fn missingArgument(field: []const u8, expected: []const u8) AppError {
    return .{
        .category = .argument,
        .operation = "parse_request",
        .phase = "validate_argument",
        .code = "missing_required_argument",
        .field = field,
        .expected = expected,
        .actual = "missing",
        .resolution = "Provide the required typed request field and retry.",
    };
}

pub fn workspacePathRejected(path: []const u8, workspace: []const u8, code: []const u8, cause: []const u8, resolution: []const u8) AppError {
    return .{
        .category = .workspace_path,
        .operation = "resolve_workspace_path",
        .phase = "workspace_boundary",
        .code = code,
        .path = path,
        .workspace = workspace,
        .cause = cause,
        .resolution = resolution,
    };
}

pub fn backendUnavailable(backend: []const u8, cause: []const u8, resolution: []const u8) AppError {
    return .{
        .category = .backend,
        .operation = "check_backend",
        .phase = "probe_backend",
        .code = "backend_unavailable",
        .retryable = true,
        .backend = backend,
        .cause = cause,
        .resolution = resolution,
    };
}

pub fn toolFailure(operation: []const u8, phase: []const u8, code: []const u8, cause: []const u8, resolution: []const u8) AppError {
    return .{
        .category = .tool,
        .operation = operation,
        .phase = phase,
        .code = code,
        .cause = cause,
        .resolution = resolution,
    };
}

test "app error captures argument metadata without transport result types" {
    const err = invalidArgument("mode", "compact, standard, or deep", "verbose", "Choose a supported mode.");
    try std.testing.expectEqual(Category.argument, err.category);
    try std.testing.expectEqualStrings("argument", err.category.name());
    try std.testing.expectEqualStrings("parse_request", err.operation);
    try std.testing.expectEqualStrings("validate_argument", err.phase);
    try std.testing.expectEqualStrings("invalid_argument", err.code);
    try std.testing.expectEqualStrings("mode", err.field.?);
    try std.testing.expectEqualStrings("verbose", err.actual.?);
    try std.testing.expect(!err.ownsMemory());
}

test "app error categories cover workspace backend and tool failures" {
    const workspace = workspacePathRejected("../outside.zig", "/repo", "path_outside_workspace", "PathOutsideWorkspace", "Use a workspace-relative path.");
    try std.testing.expectEqual(Category.workspace_path, workspace.category);
    try std.testing.expectEqualStrings("../outside.zig", workspace.path.?);
    try std.testing.expectEqualStrings("/repo", workspace.workspace.?);

    const backend = backendUnavailable("zflame", "FileNotFound", "Install zflame or configure the backend path.");
    try std.testing.expectEqual(Category.backend, backend.category);
    try std.testing.expect(backend.retryable);
    try std.testing.expectEqualStrings("zflame", backend.backend.?);

    const failed = toolFailure("profile_plan", "build_plan", "plan_failed", "InvalidInput", "Retry with a valid profiling request.");
    try std.testing.expectEqual(Category.tool, failed.category);
    try std.testing.expectEqualStrings("profile_plan", failed.operation);
}

test "generic app result carries typed data or typed error" {
    const TypedResult = Result(i64);

    const ok: TypedResult = .{ .ok = 42 };
    try std.testing.expect(ok.isOk());

    const failed: TypedResult = .{ .err = missingArgument("command", "non-empty command argv") };
    try std.testing.expect(failed.isErr());
    try std.testing.expectEqual(Category.argument, failed.err.category);
    try std.testing.expectEqualStrings("missing_required_argument", failed.err.code);
}
