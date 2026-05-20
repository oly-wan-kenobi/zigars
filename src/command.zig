const std = @import("std");
const builtin = @import("builtin");

pub const output_limit: usize = 1024 * 1024;
pub const output_limit_mode = "truncate_on_limit";

const OwnedOutput = struct {
    bytes: []u8,
    truncated: bool,
};

pub const RunResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    stdout_truncated: bool = false,
    stderr_truncated: bool = false,
    stdout_limit: usize = output_limit,
    stderr_limit: usize = output_limit,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    pub fn succeeded(self: RunResult) bool {
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
};

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    timeout_ms: i64,
) !RunResult {
    return runWithOutputLimit(allocator, io, cwd, argv, timeout_ms, output_limit, output_limit);
}

fn runWithOutputLimit(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    argv: []const []const u8,
    timeout_ms: i64,
    stdout_limit: usize,
    stderr_limit: usize,
) !RunResult {
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
    errdefer allocator.free(stdout.bytes);
    const stderr = try takeOwnedLimited(&multi_reader, allocator, 1, stderr_limit);
    errdefer allocator.free(stderr.bytes);

    return .{
        .term = term,
        .stdout = stdout.bytes,
        .stderr = stderr.bytes,
        .stdout_truncated = stdout_truncated or stdout.truncated,
        .stderr_truncated = stderr_truncated or stderr.truncated,
        .stdout_limit = stdout_limit,
        .stderr_limit = stderr_limit,
    };
}

fn argvForSpawn(allocator: std.mem.Allocator, io: std.Io, cwd: []const u8, argv: []const []const u8) ![]const []const u8 {
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
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, interpreter);
    try out.append(allocator, script_path);
    try out.appendSlice(allocator, argv[1..]);
    return out.toOwnedSlice(allocator);
}

fn executablePathForRead(allocator: std.mem.Allocator, cwd: []const u8, executable: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(executable)) return allocator.dupe(u8, executable);
    if (std.mem.indexOfScalar(u8, executable, std.fs.path.sep) == null) return error.SkipShebangDetection;
    return std.fs.path.join(allocator, &.{ cwd, executable });
}

fn parseShebang(bytes: []const u8) ?[]const u8 {
    if (bytes.len < 3 or bytes[0] != '#' or bytes[1] != '!') return null;
    const end = std.mem.indexOfScalar(u8, bytes, '\n') orelse bytes.len;
    const line = std.mem.trim(u8, bytes[2..end], " \t\r");
    if (line.len == 0) return null;
    return line;
}

fn takeOwnedLimited(multi_reader: *std.Io.File.MultiReader, allocator: std.mem.Allocator, index: usize, limit: usize) !OwnedOutput {
    const bytes = try multi_reader.toOwnedSlice(index);
    errdefer allocator.free(bytes);
    if (bytes.len <= limit) return .{ .bytes = bytes, .truncated = false };

    const trimmed = try allocator.dupe(u8, bytes[0..limit]);
    allocator.free(bytes);
    return .{ .bytes = trimmed, .truncated = true };
}

pub fn errorKind(err: anyerror) []const u8 {
    return switch (err) {
        error.Timeout => "timeout",
        error.StreamTooLong => "output_limit",
        error.FileNotFound => "executable_not_found",
        error.AccessDenied, error.PermissionDenied => "permission",
        else => "execution",
    };
}

pub fn isOutputLimitError(err: anyerror) bool {
    return err == error.StreamTooLong;
}

pub fn isTimeoutError(err: anyerror) bool {
    return err == error.Timeout;
}

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

fn finishArg(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), current: *std.ArrayList(u8)) !void {
    const arg = try current.toOwnedSlice(allocator);
    errdefer allocator.free(arg);
    try list.append(allocator, arg);
}

pub fn joinArgv(allocator: std.mem.Allocator, base: []const []const u8, extra: []const []const u8) ![]const []const u8 {
    var out = try std.ArrayList([]const u8).initCapacity(allocator, base.len + extra.len);
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, base);
    try out.appendSlice(allocator, extra);
    return out.toOwnedSlice(allocator);
}

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

pub fn termText(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => |code| if (code == 0) "exit 0" else "non-zero exit",
        .signal => "signal",
        .stopped => "stopped",
        .unknown => "unknown",
    };
}

test "split args" {
    const args = try splitArgs(std.testing.allocator, "test --summary all");
    defer {
        for (args) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(args);
    }
    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("--summary", args[1]);
}

test "split args preserves quoted values" {
    const args = try splitArgs(std.testing.allocator, "test --name 'hello zig' \"two words\" escaped\\ space");
    defer {
        for (args) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(args);
    }
    try std.testing.expectEqual(@as(usize, 5), args.len);
    try std.testing.expectEqualStrings("hello zig", args[2]);
    try std.testing.expectEqualStrings("two words", args[3]);
    try std.testing.expectEqualStrings("escaped space", args[4]);
}

test "command runner executes shebang scripts through their interpreter" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const root = ".zig-cache/tmp/command-shebang-test";
    std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, root);
    const script = ".zig-cache/tmp/command-shebang-test/echo-fixture";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = script,
        .data =
        \\#!/bin/sh
        \\printf 'script:%s\n' "$1"
        \\
        ,
        .flags = .{ .permissions = .executable_file },
    });

    const result = try run(allocator, std.testing.io, ".", &.{ script, "ok" }, 1000);
    defer result.deinit(allocator);
    try std.testing.expect(result.succeeded());
    try std.testing.expectEqualStrings("script:ok\n", result.stdout);
}

test "split args rejects unfinished quotes" {
    try std.testing.expectError(error.InvalidArguments, splitArgs(std.testing.allocator, "--name 'unterminated"));
}

test "classifies command errors" {
    try std.testing.expectEqualStrings("output_limit", errorKind(error.StreamTooLong));
    try std.testing.expect(isOutputLimitError(error.StreamTooLong));
    try std.testing.expect(isTimeoutError(error.Timeout));
}

test "run truncates oversized stdout instead of failing" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const result = try runWithOutputLimit(
        std.testing.allocator,
        std.testing.io,
        ".",
        &.{ "/bin/sh", "-c", "printf abcdef" },
        1000,
        4,
        1024,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.succeeded());
    try std.testing.expect(result.stdout_truncated);
    try std.testing.expect(!result.stderr_truncated);
    try std.testing.expectEqualStrings("abcd", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
}

test "run timeout is a total wall-clock deadline" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const io = std.testing.io;
    const started_ns = std.Io.Clock.now(.real, io).nanoseconds;
    try std.testing.expectError(error.Timeout, runWithOutputLimit(
        std.testing.allocator,
        io,
        ".",
        &.{ "/bin/sh", "-c", "printf x; sleep 1; printf y" },
        100,
        1024,
        1024,
    ));
    const elapsed_ns = std.Io.Clock.now(.real, io).nanoseconds - started_ns;

    try std.testing.expect(elapsed_ns < std.time.ns_per_s);
}
