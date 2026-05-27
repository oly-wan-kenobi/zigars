//! Diff-folded to flamegraph pipeline with explicit ownership and error-category mapping.
const std = @import("std");

const app_context = @import("../../context.zig");
const app_errors = @import("../../errors.zig");
const ports = @import("../../ports.zig");
const flamegraph_model = @import("../../../domain/profiling/flamegraph.zig");
const flamegraph = @import("flamegraph.zig");

/// Command output limit applied when collecting workflow evidence.
pub const command_output_limit: usize = 1024 * 1024;

/// Carries request data across use case and port boundaries.
pub const Request = struct {
    before: []const u8,
    after: []const u8,
    output: []const u8,
    intermediate: ?[]const u8 = null,
    options: flamegraph_model.ZflameRenderOptions = .{},
};

/// Shared owned argv type used by this workflow module.
pub const OwnedArgv = flamegraph.OwnedArgv;

/// Carries diff folded artifact data across use case and port boundaries.
pub const DiffFoldedArtifact = struct {
    backend: []const u8 = "diff-folded",
    backend_executable_path: []const u8,
    compatibility_status: []const u8 = "diff_written_and_read_ok",
    bytes: usize,
    sha256: []const u8,
    argv: OwnedArgv,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *DiffFoldedArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.sha256);
        self.argv.deinit(allocator);
        self.* = undefined;
    }
};

/// Carries resolved request data across use case and port boundaries.
pub const ResolvedRequest = struct {
    before: []const u8,
    before_abs: []const u8,
    after: []const u8,
    after_abs: []const u8,
    output: []const u8,
    output_abs: []const u8,
    intermediate: []const u8,
    intermediate_abs: []const u8,
    options: flamegraph_model.ZflameRenderOptions,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *ResolvedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.before_abs);
        allocator.free(self.after_abs);
        allocator.free(self.output_abs);
        allocator.free(self.intermediate);
        allocator.free(self.intermediate_abs);
        self.* = undefined;
    }
};

/// Carries artifact data across use case and port boundaries.
pub const Artifact = struct {
    request: ResolvedRequest,
    render: flamegraph.Artifact,
    diff: DiffFoldedArtifact,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        self.render.deinit(allocator);
        self.diff.deinit(allocator);
        self.request.deinit(allocator);
        self.* = undefined;
    }
};

/// Carries path failure data across use case and port boundaries.
pub const PathFailure = struct {
    err: ports.PortError,
    path: []const u8,
    for_output: bool = false,
};

/// Carries workspace failure data across use case and port boundaries.
pub const WorkspaceFailure = struct {
    error_info: app_errors.AppError,
    err: ports.PortError,
    path: []const u8,
    abs_path: []const u8,
};

/// Carries backend run failure data across use case and port boundaries.
pub const BackendRunFailure = struct {
    error_info: app_errors.AppError,
    err: ports.PortError,
    argv: OwnedArgv,
    cwd: []const u8,
    timeout_ms: i64,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *BackendRunFailure, allocator: std.mem.Allocator) void {
        self.argv.deinit(allocator);
        self.* = undefined;
    }
};

/// Carries command failure data across use case and port boundaries.
pub const CommandFailure = struct {
    error_info: app_errors.AppError,
    argv: OwnedArgv,
    cwd: []const u8,
    timeout_ms: i64,
    exit_code: i32,
    term: ports.CommandTerm,
    stdout: []const u8,
    stderr: []const u8,
    stdout_truncated: bool,
    stderr_truncated: bool,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *CommandFailure, allocator: std.mem.Allocator) void {
        self.argv.deinit(allocator);
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

/// Carries malformed output failure data across use case and port boundaries.
pub const MalformedOutputFailure = struct {
    error_info: app_errors.AppError,
    output: []const u8,
};

/// Carries render failure data across use case and port boundaries.
pub const RenderFailure = struct {
    request: flamegraph.Request,
    failure: flamegraph.Failure,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *RenderFailure, allocator: std.mem.Allocator) void {
        self.failure.deinit(allocator);
        self.* = undefined;
    }
};

/// Represents failure alternatives carried across the workflow boundary.
pub const Failure = union(enum) {
    workspace_path_failed: PathFailure,
    workspace_input_read_failed: WorkspaceFailure,
    workspace_parent_prepare_failed: WorkspaceFailure,
    backend_run_failed: BackendRunFailure,
    command_failed: CommandFailure,
    workspace_intermediate_read_failed: WorkspaceFailure,
    backend_output_malformed: MalformedOutputFailure,
    render_failed: RenderFailure,

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .backend_run_failed => |*failure| failure.deinit(allocator),
            .command_failed => |*failure| failure.deinit(allocator),
            .render_failed => |*failure| failure.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

/// Represents result alternatives carried across the workflow boundary.
pub const Result = union(enum) {
    ok: Artifact,
    err: struct {
        request: ?ResolvedRequest = null,
        failure: Failure,

        /// Releases allocations owned by this value; callers must not use owned slices after this returns.
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.failure.deinit(allocator);
            if (self.request) |*request| request.deinit(allocator);
            self.* = undefined;
        }
    },

    /// Releases allocations owned by this value; callers must not use owned slices after this returns.
    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        // Exactly one union arm owns heap data at a time.
        switch (self.*) {
            .ok => |*artifact| artifact.deinit(allocator),
            .err => |*failure| failure.deinit(allocator),
        }
        self.* = undefined;
    }
};

/// Produces a folded-stack diff, renders it as an SVG flamegraph, and returns both artifacts.
pub fn run(allocator: std.mem.Allocator, context: app_context.ProfilingContext, request: Request) !Result {
    var resolved = switch (try resolveRequest(allocator, context, request)) {
        .ok => |value| value,
        .err => |failure| return .{ .err = .{ .failure = .{ .workspace_path_failed = failure } } },
    };
    var resolved_owned = true;
    defer if (resolved_owned) resolved.deinit(allocator);

    // Resolve all workspace paths first so every failure can include the normalized request.
    if (try ensureInputReadable(allocator, context, resolved.before, resolved.before_abs)) |failure| {
        resolved_owned = false;
        return .{ .err = .{ .request = resolved, .failure = failure } };
    }
    if (try ensureInputReadable(allocator, context, resolved.after, resolved.after_abs)) |failure| {
        resolved_owned = false;
        return .{ .err = .{ .request = resolved, .failure = failure } };
    }
    if (try ensureOutputParent(context, resolved.intermediate, resolved.intermediate_abs)) |failure| {
        resolved_owned = false;
        return .{ .err = .{ .request = resolved, .failure = failure } };
    }

    // diff-folded writes the intermediate folded file; the next step validates and renders it.
    var diff_argv = try flamegraph_model.buildDiffFoldedArgv(allocator, .{
        .executable = context.tool_paths.diff_folded,
        .output = resolved.intermediate_abs,
        .before = resolved.before_abs,
        .after = resolved.after_abs,
    });
    defer diff_argv.deinit(allocator);

    const timeout_ms = normalizedTimeout(context.timeouts.command_ms);
    var diff = context.command_runner.run(allocator, .{
        .argv = diff_argv.argv.items,
        .cwd = context.workspace.root,
        .timeout_ms = timeout_ms,
        .max_stdout_bytes = command_output_limit,
        .max_stderr_bytes = command_output_limit,
        .provenance = "zig_flamegraph_diff diff-folded render",
    }) catch |err| {
        var owned_argv = try cloneArgv(allocator, diff_argv.argv.items);
        errdefer owned_argv.deinit(allocator);
        resolved_owned = false;
        return .{ .err = .{ .request = resolved, .failure = .{ .backend_run_failed = .{
            .error_info = app_errors.AppError{
                .category = .backend,
                .operation = "diff",
                .phase = "run_diff_folded",
                .code = "diff_folded_backend_failed",
                .retryable = true,
                .backend = "diff-folded",
                .cause = @errorName(err),
                .resolution = "confirm --diff-folded-path points to an executable diff-folded binary and both folded inputs are readable",
            },
            .err = err,
            .argv = owned_argv,
            .cwd = context.workspace.root,
            .timeout_ms = @intCast(timeout_ms),
        } } } };
    };
    defer diff.deinit(allocator);

    const command_term = diff.effectiveTerm();
    if (command_term.failed() or diff.timed_out) {
        var owned_argv = try cloneArgv(allocator, diff_argv.argv.items);
        var argv_owned = true;
        defer if (argv_owned) owned_argv.deinit(allocator);
        const stdout = try allocator.dupe(u8, diff.stdout);
        var stdout_owned = true;
        defer if (stdout_owned) allocator.free(stdout);
        const stderr = try allocator.dupe(u8, diff.stderr);
        var stderr_owned = true;
        defer if (stderr_owned) allocator.free(stderr);
        argv_owned = false;
        stdout_owned = false;
        stderr_owned = false;
        resolved_owned = false;
        return .{ .err = .{ .request = resolved, .failure = .{ .command_failed = .{
            .error_info = app_errors.AppError{
                .category = .backend,
                .operation = "diff_folded_stacks",
                .phase = "run_diff_folded",
                .code = "diff_folded_command_failed",
                .backend = "diff-folded",
                .resolution = "Inspect stdout/stderr, confirm both folded-stack inputs are readable, and retry with a working diff-folded backend.",
            },
            .argv = owned_argv,
            .cwd = context.workspace.root,
            .timeout_ms = @intCast(timeout_ms),
            .exit_code = diff.exit_code,
            .term = command_term,
            .stdout = stdout,
            .stderr = stderr,
            .stdout_truncated = diff.stdout_truncated,
            .stderr_truncated = diff.stderr_truncated,
        } } } };
    }

    // Re-read the intermediate artifact through workspace ports before passing it to zflame.
    const folded = context.workspace_store.read(allocator, .{
        .path = resolved.intermediate,
        .max_bytes = command_output_limit,
        .provenance = "zig_flamegraph_diff intermediate folded diff",
    }) catch |err| {
        resolved_owned = false;
        return .{ .err = .{ .request = resolved, .failure = .{ .workspace_intermediate_read_failed = .{
            .error_info = app_errors.toolFailure(
                "verify_intermediate_diff",
                "read_intermediate_diff",
                "workspace_artifact_read_failed",
                @errorName(err),
                "Confirm diff-folded wrote the requested --output file inside .zigars-cache/profile and retry.",
            ),
            .err = err,
            .path = resolved.intermediate,
            .abs_path = resolved.intermediate_abs,
        } } } };
    };
    defer folded.deinit(allocator);

    if (std.mem.trim(u8, folded.bytes, " \t\r\n").len == 0) {
        resolved_owned = false;
        return .{ .err = .{ .request = resolved, .failure = .{ .backend_output_malformed = .{
            .error_info = app_errors.toolFailure(
                "verify_intermediate_diff",
                "read_intermediate_diff",
                "backend_output_malformed",
                "diff-folded wrote an empty folded diff file",
                "The diff-folded command completed but wrote an empty folded diff file.",
            ),
            .output = resolved.intermediate,
        } } } };
    }

    var diff_artifact = DiffFoldedArtifact{
        .backend_executable_path = context.tool_paths.diff_folded,
        .bytes = folded.bytes.len,
        .sha256 = try sha256Hex(allocator, folded.bytes),
        .argv = try cloneArgv(allocator, diff_argv.argv.items),
    };
    var diff_artifact_owned = true;
    defer if (diff_artifact_owned) diff_artifact.deinit(allocator);

    // The nested flamegraph run owns render validation; this function wraps any render failure.
    var render = try flamegraph.run(allocator, context, .{
        .tool_name = "zig_flamegraph_diff",
        .operation = "render_differential_flamegraph",
        .input = resolved.intermediate,
        .input_abs = resolved.intermediate_abs,
        .output = resolved.output,
        .output_abs = resolved.output_abs,
        .format = .recursive,
        .options = resolved.options,
    });
    switch (render) {
        .ok => |artifact| {
            render = undefined;
            diff_artifact_owned = false;
            resolved_owned = false;
            return .{ .ok = .{
                .request = resolved,
                .render = artifact,
                .diff = diff_artifact,
            } };
        },
        .err => |failure| {
            render = undefined;
            resolved_owned = false;
            return .{ .err = .{ .request = resolved, .failure = .{ .render_failed = .{
                .request = .{
                    .tool_name = "zig_flamegraph_diff",
                    .operation = "render_differential_flamegraph",
                    .input = resolved.intermediate,
                    .input_abs = resolved.intermediate_abs,
                    .output = resolved.output,
                    .output_abs = resolved.output_abs,
                    .format = .recursive,
                    .options = resolved.options,
                },
                .failure = failure,
            } } } };
        },
    }
}

/// Represents resolve request result alternatives carried across the workflow boundary.
const ResolveRequestResult = union(enum) {
    ok: ResolvedRequest,
    err: PathFailure,
};

/// Resolves resolve request from caller-provided inputs; borrowed data remains caller-owned and failures are propagated.
fn resolveRequest(allocator: std.mem.Allocator, context: app_context.ProfilingContext, request: Request) !ResolveRequestResult {
    const before_abs = resolvePath(allocator, context, request.before, false) catch |err| return .{ .err = .{ .err = err, .path = request.before } };
    errdefer allocator.free(before_abs);
    const after_abs = resolvePath(allocator, context, request.after, false) catch |err| {
        allocator.free(before_abs);
        return .{ .err = .{ .err = err, .path = request.after } };
    };
    errdefer allocator.free(after_abs);
    const output_abs = resolvePath(allocator, context, request.output, true) catch |err| {
        allocator.free(after_abs);
        allocator.free(before_abs);
        return .{ .err = .{ .err = err, .path = request.output, .for_output = true } };
    };
    errdefer allocator.free(output_abs);
    const intermediate = if (request.intermediate) |path|
        try allocator.dupe(u8, path)
    else
        try generatedIntermediatePath(allocator, context);
    errdefer allocator.free(intermediate);
    const intermediate_abs = resolvePath(allocator, context, intermediate, true) catch |err| {
        allocator.free(intermediate);
        allocator.free(output_abs);
        allocator.free(after_abs);
        allocator.free(before_abs);
        return .{ .err = .{
            .err = err,
            .path = request.intermediate orelse "<generated intermediate>",
            .for_output = true,
        } };
    };
    errdefer allocator.free(intermediate_abs);

    return .{ .ok = .{
        .before = request.before,
        .before_abs = before_abs,
        .after = request.after,
        .after_abs = after_abs,
        .output = request.output,
        .output_abs = output_abs,
        .intermediate = intermediate,
        .intermediate_abs = intermediate_abs,
        .options = request.options,
    } };
}

/// Implements generated intermediate path workflow logic using caller-owned inputs.
fn generatedIntermediatePath(allocator: std.mem.Allocator, context: app_context.ProfilingContext) ![]const u8 {
    const clock = context.clock_and_ids orelse return error.InvalidRequest;
    const base = try clock.nextId(allocator, .{ .prefix = ".zigars-cache/profile/diff-" });
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}.folded", .{base});
}

/// Resolves resolve path from caller-provided inputs; borrowed data remains caller-owned and failures are propagated.
fn resolvePath(allocator: std.mem.Allocator, context: app_context.ProfilingContext, path: []const u8, for_output: bool) ports.PortError![]const u8 {
    const resolved = try context.workspace_store.resolve(allocator, .{
        .path = path,
        .for_output = for_output,
        .provenance = if (for_output) "profiling output path resolution" else "profiling input path resolution",
    });
    defer resolved.deinit(allocator);
    return allocator.dupe(u8, resolved.path) catch return error.OutOfMemory;
}

/// Implements ensure input readable workflow logic using caller-owned inputs.
fn ensureInputReadable(allocator: std.mem.Allocator, context: app_context.ProfilingContext, input: []const u8, input_abs: []const u8) !?Failure {
    const input_probe = context.workspace_store.read(allocator, .{
        .path = input,
        .max_bytes = 0,
        .provenance = "zig_flamegraph_diff input readability",
    }) catch |err| return .{ .workspace_input_read_failed = .{
        .error_info = app_errors.toolFailure(
            "diff_folded_stacks",
            "read_workspace_input",
            "workspace_input_read_failed",
            @errorName(err),
            "Pass an existing readable profiler input file inside the configured workspace.",
        ),
        .err = err,
        .path = input,
        .abs_path = input_abs,
    } };
    input_probe.deinit(allocator);
    return null;
}

/// Implements ensure output parent workflow logic using caller-owned inputs.
fn ensureOutputParent(context: app_context.ProfilingContext, output: []const u8, output_abs: []const u8) !?Failure {
    const parent = std.fs.path.dirname(output) orelse return null;
    _ = context.workspace_store.ensureDir(.{
        .path = parent,
        .provenance = "zig_flamegraph_diff intermediate parent",
    }) catch |err| return .{ .workspace_parent_prepare_failed = .{
        .error_info = app_errors.toolFailure(
            "prepare_backend_output",
            "create_output_parent",
            "workspace_artifact_write_failed",
            @errorName(err),
            "Choose a workspace-local output path whose parent directory can be created.",
        ),
        .err = err,
        .path = output,
        .abs_path = output_abs,
    } };
    return null;
}

/// Normalizes numeric input into the bounded value used by this workflow.
fn normalizedTimeout(timeout_ms: i64) u64 {
    if (timeout_ms <= 0) return 0;
    return @intCast(timeout_ms);
}

/// Clones argv data into allocator-owned storage.
fn cloneArgv(allocator: std.mem.Allocator, argv: []const []const u8) !OwnedArgv {
    const items = try allocator.alloc([]const u8, argv.len);
    var filled: usize = 0;
    errdefer {
        for (items[0..filled]) |arg| allocator.free(arg);
        allocator.free(items);
    }
    for (argv, 0..) |arg, index| {
        items[index] = try allocator.dupe(u8, arg);
        filled += 1;
    }
    return .{ .items = items };
}

/// Computes a lowercase SHA-256 hex digest in allocator-owned storage.
fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

const fake_command = @import("../../../testing/fakes/command_runner.zig");
const fake_workspace = @import("../../../testing/fakes/workspace_store.zig");

/// Implements test profiling context workflow logic using caller-owned inputs.
fn testProfilingContext(
    commands: *fake_command.FakeCommandRunner,
    workspace: *fake_workspace.FakeWorkspaceStore,
    clock: ?ports.ClockAndIds,
) app_context.ProfilingContext {
    return .{
        .workspace = .{ .root = "/workspace", .cache_root = "/workspace/.zigars-cache" },
        .tool_paths = .{ .zflame = "/bin/zflame", .diff_folded = "/bin/diff-folded" },
        .timeouts = .{ .command_ms = 5000 },
        .command_runner = commands.port(),
        .workspace_store = workspace.port(),
        .clock_and_ids = clock,
    };
}

/// Carries test clock data across use case and port boundaries.
const TestClock = struct {
    id: []const u8 = "case",

    /// Returns the fixture port table used by this test context.
    fn port(self: *TestClock) ports.ClockAndIds {
        return .{ .ptr = self, .vtable = &.{
            .now = now,
            .nextId = nextId,
        } };
    }

    /// Returns the fixture clock timestamp.
    fn now(_: *anyopaque) ports.PortError!ports.Instant {
        return .{ .unix_ms = 1, .monotonic_ms = 1 };
    }

    /// Allocates the next deterministic fixture identifier.
    fn nextId(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.IdRequest) ports.PortError![]const u8 {
        const self: *TestClock = @ptrCast(@alignCast(ptr));
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ request.prefix, self.id }) catch return error.OutOfMemory;
    }
};

test "flamegraph diff resolveRequest covers generated paths and path failures" {
    const allocator = std.testing.allocator;

    {
        var commands = fake_command.FakeCommandRunner.init(allocator);
        defer commands.deinit();
        var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
        defer workspace.deinit();
        var clock = TestClock{};
        const context = testProfilingContext(&commands, &workspace, clock.port());
        try std.testing.expectEqual(@as(i64, 1), (try clock.port().now()).unix_ms);

        try workspace.expectResolve(.{ .path = "before.folded", .provenance = "profiling input path resolution" }, "/workspace/before.folded");
        try workspace.expectResolveError(.{ .path = "after.folded", .provenance = "profiling input path resolution" }, error.FileNotFound);
        const result = try resolveRequest(allocator, context, .{ .before = "before.folded", .after = "after.folded", .output = "diff.svg" });
        try std.testing.expectEqual(.err, std.meta.activeTag(result));
        try std.testing.expectEqualStrings("after.folded", result.err.path);
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fake_command.FakeCommandRunner.init(allocator);
        defer commands.deinit();
        var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
        defer workspace.deinit();
        var clock = TestClock{};
        const context = testProfilingContext(&commands, &workspace, clock.port());

        try workspace.expectResolve(.{ .path = "before.folded", .provenance = "profiling input path resolution" }, "/workspace/before.folded");
        try workspace.expectResolve(.{ .path = "after.folded", .provenance = "profiling input path resolution" }, "/workspace/after.folded");
        try workspace.expectResolveError(.{ .path = "../diff.svg", .for_output = true, .provenance = "profiling output path resolution" }, error.PathOutsideWorkspace);
        const result = try resolveRequest(allocator, context, .{ .before = "before.folded", .after = "after.folded", .output = "../diff.svg" });
        try std.testing.expectEqual(.err, std.meta.activeTag(result));
        try std.testing.expect(result.err.for_output);
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fake_command.FakeCommandRunner.init(allocator);
        defer commands.deinit();
        var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
        defer workspace.deinit();
        var clock = TestClock{};
        const context = testProfilingContext(&commands, &workspace, clock.port());

        try workspace.expectResolve(.{ .path = "before.folded", .provenance = "profiling input path resolution" }, "/workspace/before.folded");
        try workspace.expectResolve(.{ .path = "after.folded", .provenance = "profiling input path resolution" }, "/workspace/after.folded");
        try workspace.expectResolve(.{ .path = "diff.svg", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/diff.svg");
        try workspace.expectResolveError(.{ .path = "../diff.folded", .for_output = true, .provenance = "profiling output path resolution" }, error.PathOutsideWorkspace);
        const result = try resolveRequest(allocator, context, .{ .before = "before.folded", .after = "after.folded", .output = "diff.svg", .intermediate = "../diff.folded" });
        try std.testing.expectEqual(.err, std.meta.activeTag(result));
        try std.testing.expectEqualStrings("../diff.folded", result.err.path);
        try commands.verify();
        try workspace.verify();
    }

    {
        var commands = fake_command.FakeCommandRunner.init(allocator);
        defer commands.deinit();
        var workspace = fake_workspace.FakeWorkspaceStore.init(allocator);
        defer workspace.deinit();
        var clock = TestClock{};
        const context = testProfilingContext(&commands, &workspace, clock.port());

        try workspace.expectResolve(.{ .path = "before.folded", .provenance = "profiling input path resolution" }, "/workspace/before.folded");
        try workspace.expectResolve(.{ .path = "after.folded", .provenance = "profiling input path resolution" }, "/workspace/after.folded");
        try workspace.expectResolve(.{ .path = "diff.svg", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/diff.svg");
        try workspace.expectResolve(.{ .path = ".zigars-cache/profile/diff-case.folded", .for_output = true, .provenance = "profiling output path resolution" }, "/workspace/.zigars-cache/profile/diff-case.folded");
        var result = try resolveRequest(allocator, context, .{ .before = "before.folded", .after = "after.folded", .output = "diff.svg" });
        defer result.ok.deinit(allocator);
        try std.testing.expectEqual(.ok, std.meta.activeTag(result));
        try std.testing.expectEqualStrings(".zigars-cache/profile/diff-case.folded", result.ok.intermediate);
        try commands.verify();
        try workspace.verify();
    }
}

test "flamegraph diff cloneArgv cleans up partial copies on allocation failure" {
    var fail_index: usize = 0;
    while (fail_index < 8) : (fail_index += 1) {
        var backing = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer backing.deinit();
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = fail_index });
        if (cloneArgv(failing.allocator(), &.{ "diff-folded", "--output=diff.folded", "before.folded", "after.folded" })) |owned| {
            var mutable = owned;
            mutable.deinit(failing.allocator());
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
    }
}
