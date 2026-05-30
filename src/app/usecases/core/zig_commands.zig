//! Core Zig command workflows with explicit argument parsing, workspace
//! boundary checks, and normalized app error mapping.
const std = @import("std");

const app_context = @import("../../context.zig");
const app_errors = @import("../../errors.zig");
const ports = @import("../../ports.zig");

/// Per-stream cap (1 MiB) on captured subprocess stdout/stderr; bounds memory
/// so a runaway or hostile command cannot exhaust the host. Output past this is
/// truncated and the result flags the truncation.
pub const command_output_limit: usize = 1024 * 1024;
/// Truncation policy label surfaced in results so callers know output past the
/// limit is dropped rather than streamed.
pub const command_output_limit_mode = "truncate_on_limit";

/// Carries owned argv data across use case and port boundaries.
pub const OwnedArgv = struct {
    items: []const []const u8,

    /// Releases each duplicated argv segment and the argv slice itself.
    pub fn deinit(self: *OwnedArgv, allocator: std.mem.Allocator) void {
        for (self.items) |arg| allocator.free(arg);
        allocator.free(self.items);
        self.* = undefined;
    }
};

/// Carries simple request data across use case and port boundaries.
pub const SimpleRequest = struct {
    timeout_ms: ?i64 = null,
};

/// Carries extra args request data across use case and port boundaries.
pub const ExtraArgsRequest = struct {
    extra_args: []const []const u8 = &.{},
    timeout_ms: ?i64 = null,
};

/// Carries test request data across use case and port boundaries.
pub const TestRequest = struct {
    file: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    timeout_ms: ?i64 = null,
};

/// Carries file command request data across use case and port boundaries.
pub const FileCommandRequest = struct {
    file: []const u8,
    extra_args: []const []const u8 = &.{},
    timeout_ms: ?i64 = null,
};

/// Carries explain request data across use case and port boundaries.
pub const ExplainRequest = struct {
    command: ?[]const u8 = null,
    file: ?[]const u8 = null,
    extra_args: []const []const u8 = &.{},
    timeout_ms: ?i64 = null,
};

/// Carries command run data across use case and port boundaries.
pub const CommandRun = struct {
    title: []const u8,
    argv: OwnedArgv,
    cwd: []const u8,
    timeout_ms: i64,
    stdout_limit: usize = command_output_limit,
    stderr_limit: usize = command_output_limit,
    result: ports.CommandResult,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *CommandRun, allocator: std.mem.Allocator) void {
        self.argv.deinit(allocator);
        self.result.deinit(allocator);
        self.* = undefined;
    }
};

/// Carries command run failure data across use case and port boundaries.
pub const CommandRunFailure = struct {
    title: []const u8,
    argv: OwnedArgv,
    cwd: []const u8,
    timeout_ms: i64,
    stdout_limit: usize = command_output_limit,
    stderr_limit: usize = command_output_limit,
    err: ports.PortError,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *CommandRunFailure, allocator: std.mem.Allocator) void {
        self.argv.deinit(allocator);
        self.* = undefined;
    }
};

/// Carries workspace failure data across use case and port boundaries.
pub const WorkspaceFailure = struct {
    error_info: app_errors.AppError,
    err: ports.PortError,
    path: []const u8,
};

/// Represents failure alternatives carried across the workflow boundary.
pub const Failure = union(enum) {
    argument: app_errors.AppError,
    workspace_path: WorkspaceFailure,
    command_run: CommandRunFailure,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .command_run => |*failure| failure.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

/// Represents command outcome alternatives carried across the workflow boundary.
pub const CommandOutcome = union(enum) {
    ok: CommandRun,
    err: Failure,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *CommandOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*run_result| run_result.deinit(allocator),
            .err => |*failure| failure.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Carries explain run data across use case and port boundaries.
pub const ExplainRun = struct {
    mode: []const u8,
    command: CommandRun,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *ExplainRun, allocator: std.mem.Allocator) void {
        allocator.free(self.mode);
        self.command.deinit(allocator);
        self.* = undefined;
    }
};

/// Represents explain outcome alternatives carried across the workflow boundary.
pub const ExplainOutcome = union(enum) {
    ok: ExplainRun,
    err: Failure,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *ExplainOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*run_result| run_result.deinit(allocator),
            .err => |*failure| failure.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Carries version result data across use case and port boundaries.
pub const VersionResult = struct {
    zig: CommandRun,
    zls: ?CommandRun = null,
    zls_status: []const u8,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *VersionResult, allocator: std.mem.Allocator) void {
        self.zig.deinit(allocator);
        if (self.zls) |*zls_run| zls_run.deinit(allocator);
        self.* = undefined;
    }
};

/// Represents version outcome alternatives carried across the workflow boundary.
pub const VersionOutcome = union(enum) {
    ok: VersionResult,
    err: Failure,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *VersionOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*version_result| version_result.deinit(allocator),
            .err => |*failure| failure.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Accumulates an owned argv vector one segment at a time. Commands are always
/// assembled as explicit argv (never a shell string), so user-supplied values
/// like file paths and extra args become individual arguments and are never
/// interpreted by a shell. Each appended segment is duped into `allocator`.
const ArgvBuilder = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator) ArgvBuilder {
        return .{ .allocator = allocator };
    }

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    fn deinit(self: *ArgvBuilder) void {
        for (self.items.items) |arg| self.allocator.free(arg);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// Dupes `arg` into the builder's allocator and appends the copy.
    fn append(self: *ArgvBuilder, arg: []const u8) !void {
        try self.items.append(self.allocator, try self.allocator.dupe(u8, arg));
    }

    /// Dupes and appends each element of `args` in order.
    fn appendMany(self: *ArgvBuilder, args: []const []const u8) !void {
        for (args) |arg| try self.append(arg);
    }

    /// Moves the accumulated argv out of the builder into an OwnedArgv; the
    /// builder is left in an empty-but-valid state so its deinit is a no-op.
    fn toOwned(self: *ArgvBuilder) !OwnedArgv {
        const owned = try self.items.toOwnedSlice(self.allocator);
        self.items = .empty;
        return .{ .items = owned };
    }
};

/// Runs `zig version` and (best-effort) `zls --version`. A ZLS command error
/// is swallowed and reported as `zls = null` in the result; only a Zig failure
/// short-circuits to `.err`. Caller owns the returned outcome.
pub fn version(allocator: std.mem.Allocator, context: app_context.CoreCommandContext, request: SimpleRequest) !VersionOutcome {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var zig_builder = ArgvBuilder.init(allocator);
    defer zig_builder.deinit();
    try zig_builder.append(context.tool_paths.zig);
    try zig_builder.append("version");
    const timeout_ms = timeoutFor(context, request.timeout_ms);
    const zig_outcome = try runBuiltCommand(allocator, context, "zig version", try zig_builder.toOwned(), timeout_ms);
    switch (zig_outcome) {
        .err => |failure| return .{ .err = failure },
        .ok => |zig_run| {
            var zls_builder = ArgvBuilder.init(allocator);
            defer zls_builder.deinit();
            try zls_builder.append(context.tool_paths.zls);
            try zls_builder.append("--version");
            var zls_outcome = try runBuiltCommand(allocator, context, "zls version", try zls_builder.toOwned(), timeout_ms);
            switch (zls_outcome) {
                .ok => |zls_run| return .{ .ok = .{
                    .zig = zig_run,
                    .zls = zls_run,
                    .zls_status = context.zls_state.status,
                } },
                .err => |*failure| {
                    failure.deinit(allocator);
                    return .{ .ok = .{
                        .zig = zig_run,
                        .zls = null,
                        .zls_status = context.zls_state.status,
                    } };
                },
            }
        },
    }
}

/// Runs `zig env` and returns the structured outcome. Caller owns the result.
pub fn env(allocator: std.mem.Allocator, context: app_context.CoreCommandContext, request: SimpleRequest) !CommandOutcome {
    var builder = ArgvBuilder.init(allocator);
    defer builder.deinit();
    try builder.append(context.tool_paths.zig);
    try builder.append("env");
    return runBuiltCommand(allocator, context, "zig env", try builder.toOwned(), timeoutFor(context, request.timeout_ms));
}

/// Runs `zig targets` and returns the structured outcome. Caller owns the result.
pub fn targets(allocator: std.mem.Allocator, context: app_context.CoreCommandContext, request: SimpleRequest) !CommandOutcome {
    var builder = ArgvBuilder.init(allocator);
    defer builder.deinit();
    try builder.append(context.tool_paths.zig);
    try builder.append("targets");
    return runBuiltCommand(allocator, context, "zig targets", try builder.toOwned(), timeoutFor(context, request.timeout_ms));
}

/// Runs `zig build [extra_args...]`. Extra args are appended verbatim as
/// individual argv elements (no shell interpolation). Caller owns the result.
pub fn build(allocator: std.mem.Allocator, context: app_context.CoreCommandContext, request: ExtraArgsRequest) !CommandOutcome {
    var builder = ArgvBuilder.init(allocator);
    defer builder.deinit();
    try builder.append(context.tool_paths.zig);
    try builder.append("build");
    try builder.appendMany(request.extra_args);
    return runBuiltCommand(allocator, context, "zig build", try builder.toOwned(), timeoutFor(context, request.timeout_ms));
}

/// Runs `zig test <file>` when a file is provided (resolved through the
/// workspace store first), or `zig build test` for the whole project suite.
/// An optional filter maps to `--test-filter`. Caller owns the result.
pub fn testCommand(allocator: std.mem.Allocator, context: app_context.CoreCommandContext, request: TestRequest) !CommandOutcome {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var builder = ArgvBuilder.init(allocator);
    defer builder.deinit();
    try builder.append(context.tool_paths.zig);
    if (request.file) |file| {
        const resolved = try resolveWorkspacePath(allocator, context, "zig_test", file, "zig_test source file");
        switch (resolved) {
            .ok => |path_result| {
                defer path_result.deinit(allocator);
                try builder.append("test");
                try builder.append(path_result.path);
            },
            .err => |failure| return .{ .err = .{ .workspace_path = failure } },
        }
        if (request.filter) |filter| {
            try builder.append("--test-filter");
            try builder.append(filter);
        }
    } else {
        try builder.append("build");
        try builder.append("test");
    }
    try builder.appendMany(request.extra_args);
    return runBuiltCommand(allocator, context, "zig test", try builder.toOwned(), timeoutFor(context, request.timeout_ms));
}

/// Runs `zig ast-check <file>` after resolving the path through the workspace
/// store. Returns a workspace-path failure when the path is outside the sandbox.
/// Caller owns the result.
pub fn check(allocator: std.mem.Allocator, context: app_context.CoreCommandContext, request: FileCommandRequest) !CommandOutcome {
    // Fail fast on the first mismatch to keep diagnostics deterministic.
    const resolved = try resolveWorkspacePath(allocator, context, "zig_check", request.file, "zig_check source file");
    switch (resolved) {
        .ok => |path_result| {
            defer path_result.deinit(allocator);
            var builder = ArgvBuilder.init(allocator);
            defer builder.deinit();
            try builder.append(context.tool_paths.zig);
            try builder.append("ast-check");
            try builder.append(path_result.path);
            return runBuiltCommand(allocator, context, "zig ast-check", try builder.toOwned(), timeoutFor(context, request.timeout_ms));
        },
        .err => |failure| return .{ .err = .{ .workspace_path = failure } },
    }
}

/// Runs `zig translate-c <file> [extra_args...]` after resolving the file path
/// through the workspace store. Caller owns the result.
pub fn translateC(allocator: std.mem.Allocator, context: app_context.CoreCommandContext, request: FileCommandRequest) !CommandOutcome {
    // Keep this logic centralized so callers observe one consistent behavior path.
    const resolved = try resolveWorkspacePath(allocator, context, "zig_translate_c", request.file, "zig_translate_c source file");
    switch (resolved) {
        .ok => |path_result| {
            defer path_result.deinit(allocator);
            var builder = ArgvBuilder.init(allocator);
            defer builder.deinit();
            try builder.append(context.tool_paths.zig);
            try builder.append("translate-c");
            try builder.append(path_result.path);
            try builder.appendMany(request.extra_args);
            return runBuiltCommand(allocator, context, "zig translate-c", try builder.toOwned(), timeoutFor(context, request.timeout_ms));
        },
        .err => |failure| return .{ .err = .{ .workspace_path = failure } },
    }
}

/// Runs the appropriate Zig sub-command for the given explain mode and returns
/// the result alongside the resolved mode string. `title` is used as the
/// command provenance tag. Valid modes: check, test, build, build-test,
/// fmt-check. Unsupported modes return `.err = .argument`. File paths are
/// resolved through the workspace store before being added to argv. Caller
/// owns the returned outcome.
pub fn explainCommand(allocator: std.mem.Allocator, context: app_context.CoreCommandContext, request: ExplainRequest, title: []const u8) !ExplainOutcome {
    const mode = request.command orelse if (request.file != null) "check" else "build-test";
    var builder = ArgvBuilder.init(allocator);
    defer builder.deinit();
    try builder.append(context.tool_paths.zig);

    // Build the argv exactly as the caller should rerun it, resolving
    // workspace-relative files only for modes that require a source path.
    if (std.mem.eql(u8, mode, "check")) {
        const file = request.file orelse return .{ .err = .{ .argument = app_errors.missingArgument("file", "workspace-relative Zig source path") } };
        const resolved = try resolveWorkspacePath(allocator, context, title, file, "core explain source file");
        switch (resolved) {
            .ok => |path_result| {
                defer path_result.deinit(allocator);
                try builder.append("ast-check");
                try builder.append(path_result.path);
            },
            .err => |failure| return .{ .err = .{ .workspace_path = failure } },
        }
    } else if (std.mem.eql(u8, mode, "test")) {
        if (request.file) |file| {
            const resolved = try resolveWorkspacePath(allocator, context, title, file, "core explain test file");
            switch (resolved) {
                .ok => |path_result| {
                    defer path_result.deinit(allocator);
                    try builder.append("test");
                    try builder.append(path_result.path);
                },
                .err => |failure| return .{ .err = .{ .workspace_path = failure } },
            }
        } else {
            try builder.append("build");
            try builder.append("test");
        }
    } else if (std.mem.eql(u8, mode, "build")) {
        try builder.append("build");
    } else if (std.mem.eql(u8, mode, "build-test")) {
        try builder.append("build");
        try builder.append("test");
    } else if (std.mem.eql(u8, mode, "fmt-check")) {
        const file = request.file orelse ".";
        const resolved = try resolveWorkspacePath(allocator, context, title, file, "core explain format target");
        switch (resolved) {
            .ok => |path_result| {
                defer path_result.deinit(allocator);
                try builder.append("fmt");
                try builder.append("--check");
                try builder.append(path_result.path);
            },
            .err => |failure| return .{ .err = .{ .workspace_path = failure } },
        }
    } else {
        return .{ .err = .{ .argument = app_errors.invalidArgument(
            "command",
            "check|test|build|build-test|fmt-check",
            mode,
            "Use one of the supported command modes, or omit command to let zigars choose build-test/check from the provided arguments.",
        ) } };
    }

    try builder.appendMany(request.extra_args);
    const owned_mode = try allocator.dupe(u8, mode);
    var mode_owned = true;
    defer if (mode_owned) allocator.free(owned_mode);
    const outcome = try runBuiltCommand(allocator, context, title, try builder.toOwned(), timeoutFor(context, request.timeout_ms));
    return switch (outcome) {
        .ok => |run_result| blk: {
            mode_owned = false;
            break :blk .{ .ok = .{ .mode = owned_mode, .command = run_result } };
        },
        .err => |failure| .{ .err = failure },
    };
}

/// Takes ownership of `argv`, invokes the command runner, and returns either
/// a `.ok` CommandRun (which owns the argv) or a `.err` CommandRunFailure
/// (which also owns the argv for diagnostics). Callers must deinit the outcome.
fn runBuiltCommand(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    title: []const u8,
    argv: OwnedArgv,
    timeout_ms: i64,
) !CommandOutcome {
    // Keep this logic centralized so callers observe one consistent behavior path.
    var owned_argv = argv;
    errdefer owned_argv.deinit(allocator);
    const result = context.command_runner.run(allocator, .{
        .argv = owned_argv.items,
        .cwd = context.workspace.root,
        .timeout_ms = @intCast(timeout_ms),
        .max_stdout_bytes = command_output_limit,
        .max_stderr_bytes = command_output_limit,
        .provenance = title,
    }) catch |err| return .{ .err = .{ .command_run = .{
        .title = title,
        .argv = owned_argv,
        .cwd = context.workspace.root,
        .timeout_ms = timeout_ms,
        .err = err,
    } } };

    return .{ .ok = .{
        .title = title,
        .argv = owned_argv,
        .cwd = context.workspace.root,
        .timeout_ms = timeout_ms,
        .result = result,
    } };
}

/// Represents resolve outcome alternatives carried across the workflow boundary.
const ResolveOutcome = union(enum) {
    ok: ports.WorkspaceResolveResult,
    err: WorkspaceFailure,
};

/// Resolves a user-supplied path through the workspace store before it is used
/// as a command argument, enforcing the sandbox boundary. A rejection (empty or
/// outside-workspace path) is returned as a structured `WorkspaceFailure` so the
/// caller reports it instead of executing the command. The unused `[]const u8`
/// parameter is the tool name, kept for call-site symmetry. `path` stays
/// caller-owned; the returned ok result owns its resolved path.
fn resolveWorkspacePath(
    allocator: std.mem.Allocator,
    context: app_context.CoreCommandContext,
    _: []const u8,
    path: []const u8,
    provenance: []const u8,
) !ResolveOutcome {
    // Normalize and constrain path handling here before any downstream filesystem action.
    const resolved = context.workspace_store.resolve(allocator, .{
        .path = path,
        .provenance = provenance,
    }) catch |err| return .{ .err = .{
        .error_info = app_errors.workspacePathRejected(
            path,
            context.workspace.root,
            if (err == error.EmptyPath) "empty_path" else "path_resolution_failed",
            @errorName(err),
            "Confirm the path exists inside the configured zigars workspace and retry.",
        ),
        .err = err,
        .path = path,
    } };
    return .{ .ok = resolved };
}

/// Returns `requested` when provided, otherwise falls back to the context
/// default, then passes both through `normalizeTimeout` to clamp the value.
pub fn timeoutFor(context: app_context.CoreCommandContext, requested: ?i64) i64 {
    return normalizeTimeout(requested orelse context.timeouts.command_ms);
}

/// Clamps a requested timeout to [1 ms, 1 hour] so a caller cannot disable the
/// timeout (<= 0) or pin a subprocess open indefinitely with a huge value.
pub fn normalizeTimeout(timeout_ms: i64) i64 {
    return @max(1, @min(timeout_ms, 60 * 60 * 1000));
}
