//! Tests for command.zig: pins arg splitting (quoting, escaping), shebang
//! interpreter rewriting, output truncation, timeout enforcement, and
//! cooperative cancellation before spawn.
const std = @import("std");
const builtin = @import("builtin");
const command = @import("command.zig");
const cancellation = @import("cancellation");

const splitArgs = command.splitArgs;
const run = command.run;
const runWithOutputLimit = command.runWithOutputLimit;
const runWithOutputLimitCancellable = command.runWithOutputLimitCancellable;
const errorKind = command.errorKind;
const isOutputLimitError = command.isOutputLimitError;
const isTimeoutError = command.isTimeoutError;

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

    var result = try run(allocator, std.testing.io, ".", &.{ script, "ok" }, 1000);
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

test "run cancels a running subprocess via the cooperative poll" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var state = cancellation.State{};
    // Flip the token from another thread after a brief spin so the subprocess is
    // already running and the wait loop is polling (exercises the in-loop
    // cancellation check, not just the pre-spawn one). A long command deadline
    // ensures the deadline never fires first.
    const Flipper = struct {
        fn run(s: *cancellation.State) void {
            // Yield a bounded number of times so the subprocess is spawned and the
            // wait loop is polling before the flip — without a long busy-spin,
            // which is pathologically slow and can stall under coverage (kcov).
            var i: usize = 0;
            while (i < 200) : (i += 1) std.Thread.yield() catch {};
            s.request("user requested cancellation");
        }
    };
    var flipper = try std.Thread.spawn(.{}, Flipper.run, .{&state});
    defer flipper.join();

    try std.testing.expectError(error.Cancelled, runWithOutputLimitCancellable(
        allocator,
        std.testing.io,
        ".",
        &.{ "/bin/sh", "-c", "sleep 30" },
        60_000,
        1024,
        1024,
        state.token(),
    ));
}

test "run observes cancellation before spawning" {
    var state = cancellation.State{};
    state.request("test cancellation");
    try std.testing.expectError(error.Cancelled, runWithOutputLimitCancellable(
        std.testing.allocator,
        std.testing.io,
        ".",
        &.{"definitely-not-spawned"},
        1000,
        1024,
        1024,
        state.token(),
    ));
}

test "run truncates oversized stdout instead of failing" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    var result = try runWithOutputLimit(
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
