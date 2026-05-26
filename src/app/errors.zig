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
