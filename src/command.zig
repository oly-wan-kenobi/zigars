const std = @import("std");

pub const output_limit: usize = 1024 * 1024;
pub const output_limit_mode = "fail_on_limit";

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
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(output_limit),
        .stderr_limit = .limited(output_limit),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = std.Io.Duration.fromMilliseconds(timeout_ms) } },
    });
    return .{
        .term = result.term,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .stdout_limit = output_limit,
        .stderr_limit = output_limit,
    };
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
        \\stdout:
        \\{s}
        \\
        \\stderr:
        \\{s}
        \\
    , .{
        title,
        termText(result.term),
        result.stdout,
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

test "split args rejects unfinished quotes" {
    try std.testing.expectError(error.InvalidArguments, splitArgs(std.testing.allocator, "--name 'unterminated"));
}

test "classifies command errors" {
    try std.testing.expectEqualStrings("output_limit", errorKind(error.StreamTooLong));
    try std.testing.expect(isOutputLimitError(error.StreamTooLong));
    try std.testing.expect(isTimeoutError(error.Timeout));
}
