const std = @import("std");
const probe = @import("probe.zig");
const fakes = @import("../../testing/fakes/root.zig");

const Runner = probe.Runner;

test "backend probe reports missing argv without invoking command runner" {
    var command_runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_runner.deinit();
    var runner = Runner.init(command_runner.port(), "/repo", 30_000);

    const availability = try runner.port().check(std.testing.allocator, .{ .backend = "zls" });
    defer availability.deinit(std.testing.allocator);
    try std.testing.expect(!availability.available);
    try std.testing.expectEqualStrings("missing probe argv", availability.unavailable_reason.?);
    try command_runner.verify();
}

test "backend probe maps command errors and non-zero exits to unavailable" {
    var command_runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_runner.deinit();
    try command_runner.expectRunError(.{
        .argv = &.{ "zls", "--version" },
        .cwd = "/repo",
        .timeout_ms = 10,
        .max_stdout_bytes = 64 * 1024,
        .max_stderr_bytes = 64 * 1024,
        .provenance = "probe-test",
    }, error.FileNotFound);
    try command_runner.expectRun(.{
        .argv = &.{ "zlint", "--version" },
        .cwd = "/repo",
        .timeout_ms = 30_000,
        .max_stdout_bytes = 64 * 1024,
        .max_stderr_bytes = 64 * 1024,
        .provenance = "backend_probe",
    }, .{ .exit_code = 1, .stderr = "bad\n" });
    var runner = Runner.init(command_runner.port(), "/repo", 30_000);

    const missing = try runner.port().check(std.testing.allocator, .{
        .backend = "zls",
        .argv = &.{ "zls", "--version" },
        .timeout_ms = 10,
        .provenance = "probe-test",
    });
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(!missing.available);
    try std.testing.expectEqualStrings("FileNotFound", missing.unavailable_reason.?);

    const nonzero = try runner.port().check(std.testing.allocator, .{
        .backend = "zlint",
        .argv = &.{ "zlint", "--version" },
    });
    defer nonzero.deinit(std.testing.allocator);
    try std.testing.expect(!nonzero.available);
    try std.testing.expectEqualStrings("exited", nonzero.unavailable_reason.?);
    try command_runner.verify();
}

test "backend probe reports successful command completion" {
    var command_runner = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer command_runner.deinit();
    try command_runner.expectRun(.{
        .argv = &.{ "zls", "--version" },
        .cwd = "/repo",
        .timeout_ms = 30_000,
        .max_stdout_bytes = 64 * 1024,
        .max_stderr_bytes = 64 * 1024,
        .provenance = "backend_probe",
    }, .{ .exit_code = 0, .stdout = "zls\n" });
    var runner = Runner.init(command_runner.port(), "/repo", 30_000);

    const availability = try runner.port().check(std.testing.allocator, .{
        .backend = "zls",
        .argv = &.{ "zls", "--version" },
    });
    defer availability.deinit(std.testing.allocator);
    try std.testing.expect(availability.available);
    try std.testing.expectEqualStrings("backend command completed", availability.basis);
    try command_runner.verify();
}
