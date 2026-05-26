//! Typed app error contract shared by all usecases to produce stable,
//! machine-readable failures without exposing transport-specific details.
/// Stable error category used by app error serializers and callers.
pub const Category = enum {
    argument,
    workspace_path,
    backend,
    tool,

    /// Returns the wire-facing category name.
    pub fn name(self: Category) []const u8 {
        return @tagName(self);
    }
};

/// Additional borrowed key/value metadata attached to an AppError.
pub const Detail = struct {
    key: []const u8,
    value: []const u8,
};

/// Borrowed, transport-neutral app error payload.
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

/// Lightweight result union used by app contracts before transport encoding.
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: AppError,

        const Self = @This();

        /// True when the result contains an ok payload.
        pub fn isOk(self: Self) bool {
            return switch (self) {
                .ok => true,
                .err => false,
            };
        }

        /// True when the result contains an AppError.
        pub fn isErr(self: Self) bool {
            return !self.isOk();
        }
    };
}

/// Builds a borrowed invalid-argument error for request validation failures.
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

/// Builds a borrowed missing-argument error for required request fields.
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

/// Builds a borrowed workspace-boundary rejection error.
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

/// Builds a retryable borrowed backend-unavailable error.
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

/// Builds a borrowed tool failure error for non-argument failures.
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
