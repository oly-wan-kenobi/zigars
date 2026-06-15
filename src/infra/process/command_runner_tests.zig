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

// NOTE: env-scrub behavior is unit-tested in command_runner.zig (scrubbedEnv)
// without spawning a child, and verified end to end by the manual cancellation /
// profiler checks. Spawning a child with a scrubbed (near-empty) environment
// under kcov corrupts ptrace child-tracking on Linux and drops coverage for
// later tests, so it is deliberately not exercised here.

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
