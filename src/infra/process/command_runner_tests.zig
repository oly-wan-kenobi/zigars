//! Tests for command_runner.Runner: pins output-limit truncation, call
//! counting, provenance tagging, timeout mapping, and port error translation.
const std = @import("std");
const command_runner = @import("command_runner.zig");

const Runner = command_runner.Runner;

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

test "process command runner scrubs child environment to the allowlist" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var parent = std.process.Environ.Map.init(allocator);
    defer parent.deinit();
    try parent.put("SECRET", "leak-me");
    try parent.put("ALLOWED", "kept-value");

    var runner = Runner.init(.{
        .io = std.testing.io,
        .default_cwd = ".",
        .default_timeout_ms = 1000,
        .environ_map = &parent,
    });

    // SECRET is in the parent but not the allowlist, so the child never sees it;
    // ALLOWED is both, so it is copied through.
    const result = try runner.port().run(allocator, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'S=[%s] A=[%s]' \"$SECRET\" \"$ALLOWED\"" },
        .env = .{ .allowlist = &.{"ALLOWED"} },
    });
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("S=[] A=[kept-value]", result.stdout);

    // Fail-closed: with no parent env wired, an allowlist yields an empty child env.
    var runner_no_parent = Runner.init(.{
        .io = std.testing.io,
        .default_cwd = ".",
        .default_timeout_ms = 1000,
    });
    const closed = try runner_no_parent.port().run(allocator, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'A=[%s]' \"$ALLOWED\"" },
        .env = .{ .allowlist = &.{"ALLOWED"} },
    });
    defer closed.deinit(allocator);
    try std.testing.expectEqualStrings("A=[]", closed.stdout);
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
