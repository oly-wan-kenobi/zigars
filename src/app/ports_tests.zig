//! Pins the port data contracts that adapters must honor: request/result structs
//! are plain borrowed data needing no transport types, CommandTerm/effectiveTerm
//! preserve non-exited outcomes and the scalar exit-code fallback, and clock/id
//! requests stay deterministic value types.
const std = @import("std");

const ports = @import("ports.zig");

test "port requests and borrowed results do not require transport types" {
    const request = ports.CommandRequest{
        .argv = &.{ "zig", "build", "test" },
        .cwd = ".",
        .timeout_ms = 30_000,
        .provenance = "unit",
    };
    try std.testing.expectEqual(@as(usize, 3), request.argv.len);
    try std.testing.expectEqualStrings("zig", request.argv[0]);

    const result = ports.CommandResult{ .exit_code = 0, .stdout = "ok" };
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("exited", result.effectiveTerm().name());
    try std.testing.expectEqual(@as(?i64, 0), result.effectiveTerm().exitCode());
    try std.testing.expectEqualStrings("ok", result.stdout);

    const delete_request = ports.WorkspaceDeleteRequest{ .path = "src/generated.zig", .missing_ok = true };
    try std.testing.expectEqualStrings("src/generated.zig", delete_request.path);
}

test "command result terms preserve non-exited outcomes" {
    const signaled = ports.CommandResult{ .term = .signal, .stdout = "partial" };
    try std.testing.expect(signaled.effectiveTerm().failed());
    try std.testing.expectEqualStrings("signal", signaled.effectiveTerm().name());
    try std.testing.expectEqual(@as(?i64, null), signaled.effectiveTerm().exitCode());

    const exit_code_fallback = ports.CommandResult{ .exit_code = 7 };
    try std.testing.expectEqualStrings("exited", exit_code_fallback.effectiveTerm().name());
    try std.testing.expectEqual(@as(?i64, 7), exit_code_fallback.effectiveTerm().exitCode());
}

test "clock and id port contracts are deterministic data" {
    const instant = ports.Instant{ .unix_ms = 1_700_000_000_000, .monotonic_ms = 42 };
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), instant.unix_ms);

    const request = ports.IdRequest{ .prefix = "artifact" };
    try std.testing.expectEqualStrings("artifact", request.prefix);
}
