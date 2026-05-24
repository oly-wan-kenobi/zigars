const std = @import("std");

const probe = @import("../../infra/backends/probe.zig");
const fakes = @import("../fakes/root.zig");

test "backend probe runner maps command success and failures" {
    var fake = fakes.FakeCommandRunner.init(std.testing.allocator);
    defer fake.deinit();
    try fake.expectRun(.{
        .argv = &.{ "tool", "--version" },
        .cwd = "/workspace",
        .timeout_ms = 1000,
        .max_stdout_bytes = 64 * 1024,
        .max_stderr_bytes = 64 * 1024,
        .provenance = "probe-test",
    }, .{ .exit_code = 0, .stdout = "tool 1\n" });

    var runner = probe.Runner.init(fake.port(), "/workspace", 1000);
    const availability = try runner.port().check(std.testing.allocator, .{
        .backend = "tool",
        .argv = &.{ "tool", "--version" },
        .cwd = "/workspace",
        .timeout_ms = 1000,
        .provenance = "probe-test",
    });
    defer availability.deinit(std.testing.allocator);
    try std.testing.expect(availability.available);
    try fake.verify();
}
