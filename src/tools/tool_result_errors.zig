const std = @import("std");
const mcp = @import("mcp");
const zigar = @import("zigar");

const command = zigar.command;
const command_output = zigar.command_output;
const tool_errors = zigar.tool_errors;

pub const CommandRunError = struct {
    tool: []const u8,
    operation: []const u8,
    phase: []const u8,
    code: []const u8,
    backend: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    timeout_ms: i64,
    err: anyerror,
    resolution: []const u8,
};

pub const CommandResultError = struct {
    tool: []const u8,
    operation: []const u8,
    phase: []const u8,
    code: []const u8,
    backend: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    timeout_ms: i64,
    result: command.RunResult,
    resolution: []const u8,
};

pub fn commandRunErrorResult(allocator: std.mem.Allocator, spec: CommandRunError) mcp.tools.ToolError!mcp.tools.ToolResult {
    const command_text = commandText(allocator, spec.argv) catch return error.OutOfMemory;
    defer allocator.free(command_text);
    const details = [_]tool_errors.Detail{
        .{ .key = "backend", .value = .{ .string = spec.backend } },
        .{ .key = "command", .value = .{ .string = command_text } },
        .{ .key = "cwd", .value = .{ .string = spec.cwd } },
        .{ .key = "timeout_ms", .value = .{ .integer = spec.timeout_ms } },
        .{ .key = "command_error_kind", .value = .{ .string = command.errorKind(spec.err) } },
    };
    return tool_errors.fromError(allocator, .{
        .tool = spec.tool,
        .operation = spec.operation,
        .phase = spec.phase,
        .code = spec.code,
        .category = "command",
        .resolution = spec.resolution,
        .details = &details,
    }, spec.err);
}

pub fn commandResultErrorResult(allocator: std.mem.Allocator, spec: CommandResultError) mcp.tools.ToolError!mcp.tools.ToolResult {
    const command_text = commandText(allocator, spec.argv) catch return error.OutOfMemory;
    defer allocator.free(command_text);
    const stdout = command_output.safeTextAlloc(allocator, spec.result.stdout) catch return error.OutOfMemory;
    defer allocator.free(stdout.text);
    const stderr = command_output.safeTextAlloc(allocator, spec.result.stderr) catch return error.OutOfMemory;
    defer allocator.free(stderr.text);
    const details = [_]tool_errors.Detail{
        .{ .key = "backend", .value = .{ .string = spec.backend } },
        .{ .key = "command", .value = .{ .string = command_text } },
        .{ .key = "cwd", .value = .{ .string = spec.cwd } },
        .{ .key = "timeout_ms", .value = .{ .integer = spec.timeout_ms } },
        .{ .key = "term", .value = .{ .string = termName(spec.result.term) } },
        .{ .key = "exit_code", .value = if (termExitCode(spec.result.term)) |code| .{ .integer = code } else .null },
        .{ .key = "stdout", .value = .{ .string = stdout.text } },
        .{ .key = "stderr", .value = .{ .string = stderr.text } },
        .{ .key = "stdout_invalid_utf8", .value = .{ .bool = stdout.invalid_utf8 } },
        .{ .key = "stderr_invalid_utf8", .value = .{ .bool = stderr.invalid_utf8 } },
        .{ .key = "stdout_encoding", .value = .{ .string = stdout.encoding } },
        .{ .key = "stderr_encoding", .value = .{ .string = stderr.encoding } },
        .{ .key = "stdout_byte_count", .value = .{ .integer = @intCast(stdout.byte_count) } },
        .{ .key = "stderr_byte_count", .value = .{ .integer = @intCast(stderr.byte_count) } },
        .{ .key = "stdout_truncated", .value = .{ .bool = spec.result.stdout_truncated } },
        .{ .key = "stderr_truncated", .value = .{ .bool = spec.result.stderr_truncated } },
        .{ .key = "output_limit_mode", .value = .{ .string = command.output_limit_mode } },
    };
    return tool_errors.result(allocator, .{
        .tool = spec.tool,
        .operation = spec.operation,
        .phase = spec.phase,
        .code = spec.code,
        .category = "backend",
        .resolution = spec.resolution,
        .details = &details,
    });
}

pub fn lspToolError(allocator: std.mem.Allocator, tool: []const u8, operation: []const u8, phase: []const u8, code: []const u8, err: anyerror, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return tool_errors.fromError(allocator, .{
        .tool = tool,
        .operation = operation,
        .phase = phase,
        .code = code,
        .category = "lsp",
        .resolution = resolution,
    }, err);
}

pub fn lspShapeError(allocator: std.mem.Allocator, tool: []const u8, operation: []const u8, phase: []const u8, code: []const u8, resolution: []const u8) mcp.tools.ToolError!mcp.tools.ToolResult {
    return tool_errors.result(allocator, .{
        .tool = tool,
        .operation = operation,
        .phase = phase,
        .code = code,
        .category = "lsp",
        .resolution = resolution,
    });
}

fn commandText(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    if (argv.len == 0) return allocator.dupe(u8, "");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (argv, 0..) |arg, index| {
        if (index > 0) try out.append(allocator, ' ');
        try out.appendSlice(allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

fn termName(term: std.process.Child.Term) []const u8 {
    return switch (term) {
        .exited => "exited",
        .signal => "signal",
        .stopped => "stopped",
        .unknown => "unknown",
    };
}

fn termExitCode(term: std.process.Child.Term) ?i64 {
    return switch (term) {
        .exited => |code| @intCast(code),
        else => null,
    };
}

test "commandText joins argv without shell interpretation" {
    const text = try commandText(std.testing.allocator, &.{ "zig", "build", "test" });
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("zig build test", text);
}

test "commandResultErrorResult sanitizes invalid UTF-8 streams" {
    const allocator = std.testing.allocator;
    const result = command.RunResult{
        .term = .{ .exited = 2 },
        .stdout = try allocator.dupe(u8, "out\xff"),
        .stderr = try allocator.dupe(u8, "err"),
    };
    defer result.deinit(allocator);

    const tool_result = try commandResultErrorResult(allocator, .{
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
