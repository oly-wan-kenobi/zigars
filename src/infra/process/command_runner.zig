//! CommandRunner port implementation: adapts real child-process execution to
//! the app port surface, mapping process/filesystem errors to stable port
//! errors and optionally recording execution telemetry via observability state.
const std = @import("std");

const ports = @import("../../app/ports.zig");
const command = @import("command.zig");
const observability_mod = @import("../observability/state.zig");

/// Runtime options for adapting subprocess execution to the CommandRunner port.
/// counter and state pointers are borrowed; the caller keeps them alive for
/// the lifetime of the Runner.
pub const Options = struct {
    io: std.Io,
    default_cwd: []const u8,
    default_timeout_ms: i64,
    command_calls: ?*usize = null,
    tool_errors: ?*usize = null,
    observability: ?*observability_mod.State = null,
    cancellation_token: ?ports.CancellationToken = null,
    count_command_calls: bool = true,
    non_exited_exit_code: i32 = -1,
    record_observability: bool = false,
};

/// CommandRunner port implementation backed by real child processes.
/// Returned stdout/stderr buffers are owned by the caller via the port result.
pub const Runner = struct {
    io: std.Io,
    default_cwd: []const u8,
    default_timeout_ms: i64,
    command_calls: ?*usize = null,
    tool_errors: ?*usize = null,
    observability: ?*observability_mod.State = null,
    cancellation_token: ?ports.CancellationToken = null,
    count_command_calls: bool = true,
    non_exited_exit_code: i32 = -1,
    record_observability: bool = false,

    const Self = @This();

    /// Captures defaults and counter pointers; the caller keeps all referenced storage alive.
    pub fn init(options: Options) Self {
        // Capture all required dependencies up front so later calls can stay predictable.
        return .{
            .io = options.io,
            .default_cwd = options.default_cwd,
            .default_timeout_ms = options.default_timeout_ms,
            .command_calls = options.command_calls,
            .tool_errors = options.tool_errors,
            .observability = options.observability,
            .cancellation_token = options.cancellation_token,
            .count_command_calls = options.count_command_calls,
            .non_exited_exit_code = options.non_exited_exit_code,
            .record_observability = options.record_observability,
        };
    }

    /// Exposes this runner through the app port vtable.
    pub fn port(self: *Self) ports.CommandRunner {
        return .{
            .ptr = self,
            .vtable = &.{
                .run = run,
            },
        };
    }

    /// Spawns the requested argv, captures bounded stdout/stderr, and returns
    /// an allocator-owned CommandResult. stdout and stderr slices are owned by
    /// the caller; call result.deinit(allocator) to free them.
    fn run(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.CommandRequest) ports.PortError!ports.CommandResult {
        // Keep this logic centralized so callers observe one consistent behavior path.
        const self: *Self = @ptrCast(@alignCast(ptr));
        const cwd = request.cwd orelse self.default_cwd;
        const timeout_ms = if (request.timeout_ms) |value| saturatingI64(value) else self.default_timeout_ms;
        const stdout_limit = request.max_stdout_bytes orelse command.output_limit;
        const stderr_limit = request.max_stderr_bytes orelse command.output_limit;
        const title = if (request.provenance.len > 0) request.provenance else "zig command";
        if (self.count_command_calls) {
            if (self.command_calls) |counter| counter.* += 1;
        }
        const started_ns = std.Io.Clock.now(.real, self.io).nanoseconds;
        const result = command.runWithOutputLimitCancellable(allocator, self.io, cwd, request.argv, timeout_ms, stdout_limit, stderr_limit, self.cancellation_token) catch |err| {
            self.recordCommand(title, request.argv, elapsedMs(self.io, started_ns), false, @errorName(err));
            if (self.record_observability) {
                if (self.tool_errors) |counter| counter.* += 1;
            }
            return mapPortError(err);
        };
        self.recordCommand(title, request.argv, result.duration_ms, result.succeeded(), null);
        return .{
            .exit_code = commandExitCode(result, self.non_exited_exit_code),
            .term = commandTerm(result.term),
            .stdout = result.stdout,
            .stderr = result.stderr,
            .duration_ms = if (result.duration_ms <= 0) 0 else @intCast(result.duration_ms),
            .timed_out = false,
            .stdout_truncated = result.stdout_truncated,
            .stderr_truncated = result.stderr_truncated,
            .provenance = request.provenance,
            .owns_stdout = true,
            .owns_stderr = true,
        };
    }

    /// Records a command execution event from captured process output.
    fn recordCommand(self: *Self, title: []const u8, argv: []const []const u8, duration_ms: i64, ok: bool, error_name: ?[]const u8) void {
        if (!self.record_observability) return;
        if (self.observability) |state| state.recordCommand(title, argv, duration_ms, ok, error_name);
    }
};

/// Normalizes process/filesystem failures into the app port error surface.
pub fn mapPortError(err: anyerror) ports.PortError {
    // Preserve a single error-shaping path so callers receive consistent metadata.
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.Timeout => error.Timeout,
        error.RequestTimeout => error.RequestTimeout,
        error.EndOfStream => error.EndOfStream,
        error.BrokenPipe => error.BrokenPipe,
        error.Cancelled => error.Cancelled,
        error.PathOutsideWorkspace => error.PathOutsideWorkspace,
        error.EmptyPath => error.EmptyPath,
        error.StreamTooLong => error.StreamTooLong,
        error.InvalidArguments => error.InvalidRequest,
        else => error.Unavailable,
    };
}

/// Maps child-process termination into the domain command status.
fn commandTerm(term: std.process.Child.Term) ports.CommandTerm {
    return switch (term) {
        .exited => |code| .{ .exited = @intCast(code) },
        .signal => .signal,
        .stopped => .stopped,
        .unknown => .unknown,
    };
}

/// Extracts the numeric exit code from a termination status when present.
fn commandExitCode(result: command.RunResult, non_exited_exit_code: i32) i32 {
    return switch (result.term) {
        .exited => |code| @intCast(code),
        else => non_exited_exit_code,
    };
}

/// Converts unsigned counters to i64 without overflow.
fn saturatingI64(value: u64) i64 {
    const max_i64: u64 = @intCast(std.math.maxInt(i64));
    if (value > max_i64) return std.math.maxInt(i64);
    return @intCast(value);
}

/// Converts elapsed nanoseconds to saturated milliseconds.
/// Uses wall-clock (.real) so the duration reflects calendar time for
/// observability records, matching user-visible timeout semantics.
fn elapsedMs(io: std.Io, started_ns: anytype) i64 {
    const duration_ns = std.Io.Clock.now(.real, io).nanoseconds - started_ns;
    if (duration_ns <= 0) return 0;
    return @intCast(@divTrunc(duration_ns, std.time.ns_per_ms));
}
