const std = @import("std");

const app_context = @import("../../context.zig");
const app_errors = @import("../../errors.zig");
const ports = @import("../../ports.zig");
const flamegraph_model = @import("../../../domain/profiling/flamegraph.zig");

pub const command_output_limit: usize = 1024 * 1024;
pub const ZflameFormat = flamegraph_model.ZflameFormat;
pub const ZflameRenderOptions = flamegraph_model.ZflameRenderOptions;

pub const Request = struct {
    tool_name: []const u8 = "zig_flamegraph",
    operation: []const u8 = "render_flamegraph",
    input: []const u8,
    input_abs: []const u8,
    output: []const u8,
    output_abs: []const u8,
    format: ZflameFormat,
    options: ZflameRenderOptions = .{},
};

pub const OwnedArgv = struct {
    items: [][]const u8,

    pub fn deinit(self: *OwnedArgv, allocator: std.mem.Allocator) void {
        for (self.items) |arg| allocator.free(arg);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const Artifact = struct {
    backend: []const u8 = "zflame",
    backend_executable_path: []const u8,
    compatibility_status: []const u8 = "rendered_ok",
    bytes: usize,
    sha256: []const u8,
    argv: OwnedArgv,

    pub fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.sha256);
        self.argv.deinit(allocator);
        self.* = undefined;
    }
};

pub const WorkspaceFailure = struct {
    error_info: app_errors.AppError,
    err: ports.PortError,
    path: []const u8,
    abs_path: []const u8,
};

pub const BackendRunFailure = struct {
    error_info: app_errors.AppError,
    err: ports.PortError,
    argv: OwnedArgv,
    cwd: []const u8,
    timeout_ms: i64,

    pub fn deinit(self: *BackendRunFailure, allocator: std.mem.Allocator) void {
        self.argv.deinit(allocator);
        self.* = undefined;
    }
};

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

    pub fn deinit(self: *CommandFailure, allocator: std.mem.Allocator) void {
        self.argv.deinit(allocator);
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

pub const MalformedOutputFailure = struct {
    error_info: app_errors.AppError,
    backend: []const u8,
    format: ZflameFormat,
    input: []const u8,
};

pub const Failure = union(enum) {
    workspace_input_read_failed: WorkspaceFailure,
    backend_run_failed: BackendRunFailure,
    command_failed: CommandFailure,
    backend_output_malformed: MalformedOutputFailure,
    workspace_artifact_write_failed: WorkspaceFailure,

    pub fn deinit(self: *Failure, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .backend_run_failed => |*failure| failure.deinit(allocator),
            .command_failed => |*failure| failure.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    ok: Artifact,
    err: Failure,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*artifact| artifact.deinit(allocator),
            .err => |*failure| failure.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator, context: app_context.ProfilingContext, request: Request) !Result {
    if (request.input.len == 0) return .{ .err = .{ .workspace_input_read_failed = .{
        .error_info = app_errors.missingArgument("input", "workspace-relative profiler input path"),
        .err = error.InvalidRequest,
        .path = request.input,
        .abs_path = request.input_abs,
    } } };
    if (request.output.len == 0) return .{ .err = .{ .workspace_artifact_write_failed = .{
        .error_info = app_errors.missingArgument("output", "workspace-relative SVG output path"),
        .err = error.InvalidRequest,
        .path = request.output,
        .abs_path = request.output_abs,
    } } };

    const input_probe = context.workspace_store.read(allocator, .{
        .path = request.input,
        .max_bytes = 0,
        .provenance = "zig_flamegraph input readability",
    }) catch |err| return .{ .err = .{ .workspace_input_read_failed = .{
        .error_info = app_errors.toolFailure(
            request.operation,
            "read_workspace_input",
            "workspace_input_read_failed",
            @errorName(err),
            "Pass an existing readable profiler input file inside the configured workspace.",
        ),
        .err = err,
        .path = request.input,
        .abs_path = request.input_abs,
    } } };
    input_probe.deinit(allocator);

    var argv = try flamegraph_model.buildZflameArgv(allocator, .{
        .executable = context.tool_paths.zflame,
        .format = request.format,
        .input = request.input_abs,
        .options = request.options,
    });
    defer argv.deinit(allocator);

    const timeout_ms = normalizedTimeout(context.timeouts.command_ms);
    var command_result = context.command_runner.run(allocator, .{
        .argv = argv.argv.items,
        .cwd = context.workspace.root,
        .timeout_ms = timeout_ms,
        .max_stdout_bytes = command_output_limit,
        .max_stderr_bytes = command_output_limit,
        .provenance = "zig_flamegraph zflame render",
    }) catch |err| {
        var owned_argv = try cloneArgv(allocator, argv.argv.items);
        errdefer owned_argv.deinit(allocator);
        return .{ .err = .{ .backend_run_failed = .{
            .error_info = app_errors.AppError{
                .category = .backend,
                .operation = "render",
                .phase = "run_zflame",
                .code = "zflame_backend_failed",
                .retryable = true,
                .backend = "zflame",
                .cause = @errorName(err),
                .resolution = "confirm --zflame-path points to an executable zflame binary and that profiler input is readable",
            },
            .err = err,
            .argv = owned_argv,
            .cwd = context.workspace.root,
            .timeout_ms = @intCast(timeout_ms),
        } } };
    };
    defer command_result.deinit(allocator);

    const command_term = command_result.effectiveTerm();
    if (command_term.failed() or command_result.timed_out) {
        var owned_argv = try cloneArgv(allocator, argv.argv.items);
        errdefer owned_argv.deinit(allocator);
        const stdout = try allocator.dupe(u8, command_result.stdout);
        errdefer allocator.free(stdout);
        const stderr = try allocator.dupe(u8, command_result.stderr);
        errdefer allocator.free(stderr);
        return .{ .err = .{ .command_failed = .{
            .error_info = app_errors.AppError{
                .category = .backend,
                .operation = request.operation,
                .phase = "run_zflame",
                .code = "zflame_command_failed",
                .backend = "zflame",
                .resolution = "Inspect stdout/stderr, confirm the profiler input format is correct, and retry with a supported zflame invocation.",
            },
            .argv = owned_argv,
            .cwd = context.workspace.root,
            .timeout_ms = @intCast(timeout_ms),
            .exit_code = command_result.exit_code,
            .term = command_term,
            .stdout = stdout,
            .stderr = stderr,
            .stdout_truncated = command_result.stdout_truncated,
            .stderr_truncated = command_result.stderr_truncated,
        } } };
    }

    if (!flamegraph_model.looksLikeSvg(command_result.stdout)) return .{ .err = .{ .backend_output_malformed = .{
        .error_info = app_errors.toolFailure(
            request.operation,
            "validate_svg",
            "backend_output_malformed",
            "zflame stdout was not SVG",
            "The zflame command completed but stdout did not look like an SVG document. Run zflame directly with the same input and options.",
        ),
        .backend = "zflame",
        .format = request.format,
        .input = request.input,
    } } };

    _ = context.workspace_store.write(.{
        .path = request.output,
        .bytes = command_result.stdout,
        .create_parent_dirs = true,
        .replace_existing = true,
        .provenance = "zig_flamegraph SVG artifact",
    }) catch |err| return .{ .err = .{ .workspace_artifact_write_failed = .{
        .error_info = app_errors.toolFailure(
            request.operation,
            "workspace_write",
            "workspace_artifact_write_failed",
            @errorName(err),
            "Choose an output path inside the workspace that zigar can create or overwrite.",
        ),
        .err = err,
        .path = request.output,
        .abs_path = request.output_abs,
    } } };

    var owned_argv = try cloneArgv(allocator, argv.argv.items);
    errdefer owned_argv.deinit(allocator);
    const hash = try sha256Hex(allocator, command_result.stdout);
    errdefer allocator.free(hash);

    return .{ .ok = .{
        .backend_executable_path = context.tool_paths.zflame,
        .bytes = command_result.stdout.len,
        .sha256 = hash,
        .argv = owned_argv,
    } };
}

fn normalizedTimeout(timeout_ms: i64) u64 {
    if (timeout_ms <= 0) return 0;
    return @intCast(timeout_ms);
}

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

fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}
