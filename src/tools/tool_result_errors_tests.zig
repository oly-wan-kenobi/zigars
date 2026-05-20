const std = @import("std");
const zigar = @import("zigar");

const tool_result_errors = @import("tool_result_errors.zig");

test "commandResultErrorResult sanitizes invalid UTF-8 streams" {
    const allocator = std.testing.allocator;
    const result = zigar.command.RunResult{
        .term = .{ .exited = 2 },
        .stdout = try allocator.dupe(u8, "out\xff"),
        .stderr = try allocator.dupe(u8, "err"),
    };
    defer result.deinit(allocator);

    const tool_result = try tool_result_errors.commandResultErrorResult(allocator, .{
        .tool = "zig_flamegraph",
        .operation = "render",
        .phase = "run_backend",
        .code = "backend_failed",
        .backend = "zflame",
        .argv = &.{ "zflame", "input.folded" },
        .cwd = ".",
        .timeout_ms = 1000,
        .result = result,
        .resolution = "Inspect backend output and retry.",
    });
    defer zigar.json_result.deinitToolResult(allocator, tool_result);

    const obj = tool_result.structuredContent.?.object;
    try std.testing.expect(obj.get("stdout_invalid_utf8").?.bool);
    try std.testing.expect(!obj.get("stderr_invalid_utf8").?.bool);
    try std.testing.expectEqualStrings("utf-8-lossy", obj.get("stdout_encoding").?.string);
    try std.testing.expect(std.unicode.utf8ValidateSlice(obj.get("stdout").?.string));
}
