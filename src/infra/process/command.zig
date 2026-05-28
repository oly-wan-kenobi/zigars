//! Runs subprocesses with bounded output capture and timeout enforcement.
const std = @import("std");
const builtin = @import("builtin");
const cancellation = @import("cancellation");

/// Default byte cap for stdout and stderr capture.
pub const output_limit: usize = 1024 * 1024;
/// Stable label describing output-limit behavior in result contracts.
pub const output_limit_mode = "truncate_on_limit";

/// Owned process output captured after applying byte limits and termination policy.
const OwnedOutput = struct {
    bytes: []u8,
    truncated: bool,
};

/// Owned result of a subprocess run; caller must deinit captured streams.
pub const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    stdout_limit: usize = output_limit,
    stderr_limit: usize = output_limit,
    duration_ms: i64 = 0,

    /// Frees captured stdout and stderr buffers.
    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    /// True when the process exited with status code zero.
    pub fn succeeded(self: RunResult) bool {
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

/// Runs argv with default stdout/stderr limits.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    timeout_ms: i64,
) !RunResult {
    return runWithOutputLimit(allocator, io, cwd, argv, timeout_ms, output_limit, output_limit);
}

/// Runs argv with explicit stdout/stderr caps and timeout enforcement.
pub fn runWithOutputLimit(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    timeout_ms: i64,
    stdout_limit: usize,
    stderr_limit: usize,
) !RunResult {
    return runWithOutputLimitCancellable(allocator, io, cwd, argv, timeout_ms, stdout_limit, stderr_limit, null);
}

/// Runs argv with explicit stdout/stderr caps, timeout enforcement, and optional cooperative cancellation.
pub fn runWithOutputLimitCancellable(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    timeout_ms: i64,
    stdout_limit: usize,
    stderr_limit: usize,
    token: ?cancellation.Token,
) !RunResult {
    if (isCancelled(token)) return error.Cancelled;
    // Spawn argv may be rewritten to honor script shebang interpreters on POSIX.
    var spawn_arena = std.heap.ArenaAllocator.init(allocator);
    defer spawn_arena.deinit();
    const spawn_argv = try argvForSpawn(spawn_arena.allocator(), io, cwd, argv);

    var child = try std.process.spawn(io, .{
        .argv = spawn_argv,
        .cwd = .{ .path = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    var child_active = true;
    defer if (child_active) child.kill(io);

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    var stdout_truncated = false;
    var stderr_truncated = false;
    var term: std.process.Child.Term = .{ .unknown = 0 };
    const started_ns = std.Io.Clock.now(.real, io).nanoseconds;
    const timeout_ns = @as(i96, timeout_ms) * std.time.ns_per_ms;
    const deadline_ns = started_ns + timeout_ns;

    while (true) {
        if (isCancelled(token)) {
            multi_reader.batch.cancel(io);
            child.kill(io);
            child_active = false;
            return error.Cancelled;
        }
        const now_ns = std.Io.Clock.now(.real, io).nanoseconds;
        if (now_ns >= deadline_ns) return error.Timeout;
        const remaining_ns = deadline_ns - now_ns;
        const remaining_ms: i64 = @intCast(@divTrunc(remaining_ns + std.time.ns_per_ms - 1, std.time.ns_per_ms));
        const timeout = std.Io.Timeout{ .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(@max(1, remaining_ms)) } };
        multi_reader.fill(64, timeout) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (stdout_reader.buffered().len > stdout_limit) stdout_truncated = true;
        if (stderr_reader.buffered().len > stderr_limit) stderr_truncated = true;
        if (stdout_truncated or stderr_truncated) {
            // Stop background reads before killing the child to avoid hanging batch waiters.
            multi_reader.batch.cancel(io);
            child.kill(io);
            child_active = false;
            break;
        }
    }

    if (!stdout_truncated and !stderr_truncated) {
        try multi_reader.checkAnyError();
        term = try child.wait(io);
        child_active = false;
    }

    const stdout = try takeOwnedLimited(&multi_reader, allocator, 0, stdout_limit);
    var stdout_owned = true;
    defer if (stdout_owned) allocator.free(stdout.bytes);
    const stderr = try takeOwnedLimited(&multi_reader, allocator, 1, stderr_limit);
    var stderr_owned = true;
    defer if (stderr_owned) allocator.free(stderr.bytes);

    stdout_owned = false;
    stderr_owned = false;
    return .{
        .term = term,
        .stdout = stdout.bytes,
        .stderr = stderr.bytes,
        .stdout_truncated = stdout_truncated or stdout.truncated,
        .stderr_truncated = stderr_truncated or stderr.truncated,
        .stdout_limit = stdout_limit,
        .stderr_limit = stderr_limit,
        .duration_ms = elapsedMs(io, started_ns),
    };
}

fn isCancelled(token: ?cancellation.Token) bool {
    return if (token) |value| value.isCancelled() else false;
}

/// Converts elapsed nanoseconds to saturated milliseconds.
fn elapsedMs(io: std.Io, started_ns: anytype) i64 {
    const finished_ns = std.Io.Clock.now(.real, io).nanoseconds;
    const duration_ns = finished_ns - started_ns;
    if (duration_ns <= 0) return 0;
    return @intCast(@divTrunc(duration_ns, std.time.ns_per_ms));
}

/// Converts the command argument list into argv for child process spawn.
fn argvForSpawn(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8) ![]const []const u8 {
    // Windows command launching differs enough that shebang rewriting is skipped.
    if (argv.len == 0 or builtin.os.tag == .windows) return argv;

    const script_path = executablePathForRead(allocator, cwd, argv[0]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return argv,
    };
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, script_path, allocator, .limited(4096)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return argv,
    };
    defer allocator.free(bytes);

    const shebang = parseShebang(bytes) orelse return argv;
    const interpreter = splitArgs(allocator, shebang) catch return argv;
    if (interpreter.len == 0) return argv;

    var out: std.ArrayList([]const u8) = .empty;
    var out_owned = true;
    defer if (out_owned) out.deinit(allocator);
    try out.appendSlice(allocator, interpreter);
    try out.append(allocator, script_path);
    try out.appendSlice(allocator, argv[1..]);
    const spawn_argv = try out.toOwnedSlice(allocator);
    out_owned = false;
    return spawn_argv;
}

/// Reads the executable path referenced by a shebang line.
fn executablePathForRead(allocator: std.mem.Allocator, cwd: []const u8, executable: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(executable)) return allocator.dupe(u8, executable);
    if (std.mem.indexOfScalar(u8, executable, std.fs.path.sep) == null) return error.SkipShebangDetection;
    return std.fs.path.join(allocator, &.{ cwd, executable });
}

/// Parses shebang from caller-owned input and reports malformed data without taking ownership.
fn parseShebang(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 3 or bytes[0] != '#' or bytes[1] != '!') return null;
    const end = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    const line = std.mem.trim(u8, bytes[2..end], " \t\r");
    if (line.len == 0) return null;
    return line;
}

/// Transfers captured bytes into owned output after enforcing the byte limit.
fn takeOwnedLimited(multi_reader: *std.Io.File.MultiReader, allocator: std.mem.Allocator, index: usize, limit: usize) !OwnedOutput {
    const bytes = try multi_reader.toOwnedSlice(index);
    var bytes_owned = true;
    defer if (bytes_owned) allocator.free(bytes);
    if (bytes.len <= limit) {
        bytes_owned = false;
        return .{ .bytes = bytes, .truncated = false };
    }

    // Preserve deterministic upper bounds even if read buffers raced past `limit`.
    const trimmed = try allocator.dupe(u8, bytes[0..limit]);
    allocator.free(bytes);
    bytes_owned = false;
    return .{ .bytes = trimmed, .truncated = true };
}

/// Classifies process errors into stable user-facing categories.
pub fn errorKind(err: anyerror) []const u8 {
    return switch (err) {
        error.Timeout => "timeout",
        error.StreamTooLong => "output_limit",
        error.FileNotFound => "executable_not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        else => "execution",
    };
}

/// True when an error came from bounded output capture.
pub fn isOutputLimitError(err: anyerror) bool {
    return err == error.StreamTooLong;
}

/// True when an error came from timeout enforcement.
pub fn isTimeoutError(err: anyerror) bool {
    return err == error.Timeout;
}

/// Splits shell-like extra arguments into an owned argv list.
pub fn splitArgs(allocator: std.mem.Allocator, text: ?[]const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    errdefer {
        for (list.items) |arg| allocator.free(arg);
        list.deinit(allocator);
        current.deinit(allocator);
    }
    if (text) |value| {
        var quote: ?u8 = null;
        var escaping = false;
        var in_token = false;
        for (value) |c| {
            if (escaping) {
                try current.append(allocator, c);
                in_token = true;
                escaping = false;
                continue;
            }
            if (c == '\\') {
                escaping = true;
                in_token = true;
                continue;
            }
            if (quote) |q| {
                if (c == q) {
                    quote = null;
                } else {
                    try current.append(allocator, c);
                }
                in_token = true;
                continue;
            }
            switch (c) {
                '\'', '"' => {
                    quote = c;
                    in_token = true;
                },
                ' ', '\t', '\r', '\n' => {
                    if (in_token) {
                        try finishArg(allocator, &list, &current);
                        in_token = false;
                    }
                },
                else => {
                    try current.append(allocator, c);
                    in_token = true;
                },
            }
        }
        if (escaping or quote != null) return error.InvalidArguments;
        if (in_token) try finishArg(allocator, &list, &current);
    }
    return list.toOwnedSlice(allocator);
}

/// Completes the current argument token while parsing a shell command line.
fn finishArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), current: *std.ArrayList(u8)) !void {
    const arg = try current.toOwnedSlice(allocator);
    var arg_owned = true;
    defer if (arg_owned) allocator.free(arg);
    try list.append(allocator, arg);
    arg_owned = false;
}

/// Concatenates two borrowed argv lists into an owned argv slice.
pub fn joinArgv(allocator: std.mem.Allocator, base: []const []const u8, extra: []const []const u8) ![]const []const u8 {
    var out = try std.ArrayList([]const u8).initCapacity(allocator, base.len + extra.len);
    var out_owned = true;
    defer if (out_owned) out.deinit(allocator);
    try out.appendSlice(allocator, base);
    try out.appendSlice(allocator, extra);
    const argv = try out.toOwnedSlice(allocator);
    out_owned = false;
    return argv;
}

/// Formats command output and captured stderr/stdout into a caller-owned text block.
pub fn formatRunResult(allocator: std.mem.Allocator, title: []const u8, result: RunResult) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{s}
        \\status: {s}
        \\
        \\stdout{s}:
        \\{s}
        \\
        \\stderr{s}:
        \\{s}
        \\
    , .{
        title,
        termText(result.term),
        if (result.stdout_truncated) " (truncated)" else "",
        result.stdout,
        if (result.stderr_truncated) " (truncated)" else "",
        result.stderr,
    });
}

/// Converts child termination state to stable text.
pub fn termText(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => |code| if (code == 0) "exit 0" else "non-zero exit",
        .signal => "signal",
        .stopped => "stopped",
        .unknown => "unknown",
    };
}

test "argv shebang detection preserves oom from path and file reads" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const root = ".zig-cache/tmp/command-argv-oom-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    const script = ".zig-cache/tmp/command-argv-oom-test/script";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = script,
        .data =
        \\#!/bin/sh
        \\echo ok
        \\
        ,
        .flags = .{ .permissions = .executable_file },
    });

    var path_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var path_arena = std.heap.ArenaAllocator.init(path_failing.allocator());
    defer path_arena.deinit();
    try std.testing.expectError(error.OutOfMemory, argvForSpawn(path_arena.allocator(), std.testing.io, ".", &.{script}));

    var read_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var read_arena = std.heap.ArenaAllocator.init(read_failing.allocator());
    defer read_arena.deinit();
    try std.testing.expectError(error.OutOfMemory, argvForSpawn(read_arena.allocator(), std.testing.io, ".", &.{script}));
}
