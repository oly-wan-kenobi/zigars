const std = @import("std");

const ports = @import("../../app/ports.zig");
const command = @import("../../command.zig");
const observability_mod = @import("../../observability.zig");

pub const Options = struct {
    io: std.Io,
    default_cwd: []const u8,
    default_timeout_ms: i64,
    command_calls: ?*usize = null,
    tool_errors: ?*usize = null,
    observability: ?*observability_mod.State = null,
    non_exited_exit_code: i32 = -1,
    record_observability: bool = false,
};

pub const Runner = struct {
    io: std.Io,
    default_cwd: []const u8,
    default_timeout_ms: i64,
    command_calls: ?*usize = null,
    tool_errors: ?*usize = null,
    observability: ?*observability_mod.State = null,
    non_exited_exit_code: i32 = -1,
    record_observability: bool = false,

    const Self = @This();

    pub fn init(options: Options) Self {
        return .{
            .io = options.io,
            .default_cwd = options.default_cwd,
            .default_timeout_ms = options.default_timeout_ms,
            .command_calls = options.command_calls,
            .tool_errors = options.tool_errors,
            .observability = options.observability,
            .non_exited_exit_code = options.non_exited_exit_code,
            .record_observability = options.record_observability,
        };
    }

    pub fn port(self: *Self) ports.CommandRunner {
        return .{
            .ptr = self,
            .vtable = &.{
                .run = run,
            },
        };
    }

    fn run(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.CommandRequest) ports.PortError!ports.CommandResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const cwd = request.cwd orelse self.default_cwd;
        const timeout_ms = if (request.timeout_ms) |value| saturatingI64(value) else self.default_timeout_ms;
        const stdout_limit = request.max_stdout_bytes orelse command.output_limit;
        const stderr_limit = request.max_stderr_bytes orelse command.output_limit;
        const title = if (request.provenance.len > 0) request.provenance else "zig command";
        if (self.command_calls) |counter| counter.* += 1;
        const started_ns = std.Io.Clock.now(.real, self.io).nanoseconds;
        const result = command.runWithOutputLimit(allocator, self.io, cwd, request.argv, timeout_ms, stdout_limit, stderr_limit) catch |err| {
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

    fn recordCommand(self: *Self, title: []const u8, argv: []const []const u8, duration_ms: i64, ok: bool, error_name: ?[]const u8) void {
        if (!self.record_observability) return;
        if (self.observability) |state| state.recordCommand(title, argv, duration_ms, ok, error_name);
    }
};

pub fn mapPortError(err: anyerror) ports.PortError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.PermissionDenied => error.PermissionDenied,
        error.Timeout => error.Timeout,
        error.RequestTimeout => error.RequestTimeout,
        error.EndOfStream => error.EndOfStream,
        error.BrokenPipe => error.BrokenPipe,
        error.PathOutsideWorkspace => error.PathOutsideWorkspace,
        error.EmptyPath => error.EmptyPath,
        error.StreamTooLong => error.StreamTooLong,
        error.InvalidArguments => error.InvalidRequest,
        else => error.Unavailable,
    };
}

fn commandTerm(term: std.process.Child.Term) ports.CommandTerm {
    return switch (term) {
        .exited => |code| .{ .exited = @intCast(code) },
        .signal => .signal,
        .stopped => .stopped,
        .unknown => .unknown,
    };
}

fn commandExitCode(result: command.RunResult, non_exited_exit_code: i32) i32 {
    return switch (result.term) {
        .exited => |code| @intCast(code),
        else => non_exited_exit_code,
    };
}

fn saturatingI64(value: u64) i64 {
    const max_i64: u64 = @intCast(std.math.maxInt(i64));
    if (value > max_i64) return std.math.maxInt(i64);
    return @intCast(value);
}

fn elapsedMs(io: std.Io, started_ns: anytype) i64 {
    const duration_ns = std.Io.Clock.now(.real, io).nanoseconds - started_ns;
    if (duration_ns <= 0) return 0;
    return @intCast(@divTrunc(duration_ns, std.time.ns_per_ms));
}

test "process command runner maps output limits counters and provenance" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var calls: usize = 0;
    var runner = Runner.init(.{
        .io = std.testing.io,
        .default_cwd = ".",
        .default_timeout_ms = 1000,
        .command_calls = &calls,
    });

    const result = try runner.port().run(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "printf abcdef" },
        .max_stdout_bytes = 4,
        .provenance = "infra-test",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expect(result.stdout_truncated);
    try std.testing.expectEqualStrings("abcd", result.stdout);
    try std.testing.expectEqualStrings("infra-test", result.provenance);
}

test "process command runner maps timeout to port timeout error" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var runner = Runner.init(.{
        .io = std.testing.io,
        .default_cwd = ".",
        .default_timeout_ms = 1000,
    });

    try std.testing.expectError(error.Timeout, runner.port().run(std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 1" },
        .timeout_ms = 20,
    }));
}
