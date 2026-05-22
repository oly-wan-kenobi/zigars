const std = @import("std");
const zigar = @import("zigar");

const command = zigar.command;
const command_output = zigar.command_output;
const ports = zigar.app.ports;
const command_result = @import("command_result.zig");

pub fn commandTermValue(allocator: std.mem.Allocator, term: ports.CommandTerm) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    switch (term) {
        .exited => |code| {
            try obj.put(allocator, "kind", .{ .string = "exited" });
            try obj.put(allocator, "code", .{ .integer = @intCast(code) });
        },
        .signal => try obj.put(allocator, "kind", .{ .string = "signal" }),
        .stopped => try obj.put(allocator, "kind", .{ .string = "stopped" }),
        .unknown => try obj.put(allocator, "kind", .{ .string = "unknown" }),
    }
    return .{ .object = obj };
}

pub fn commandResultValue(
    allocator: std.mem.Allocator,
    title: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    timeout_ms: i64,
    stdout_limit: usize,
    stderr_limit: usize,
    result: ports.CommandResult,
) !std.json.Value {
    var obj = std.json.ObjectMap.empty;
    errdefer obj.deinit(allocator);
    const term = result.effectiveTerm();
    const ok = !term.failed() and !result.timed_out;
    try obj.put(allocator, "kind", .{ .string = "command" });
    try obj.put(allocator, "title", .{ .string = title });
    try obj.put(allocator, "ok", .{ .bool = ok });
    try obj.put(allocator, "cwd", .{ .string = cwd });
    try obj.put(allocator, "argv", try command_result.argvValue(allocator, argv));
    try obj.put(allocator, "timeout_ms", .{ .integer = timeout_ms });
    try obj.put(allocator, "duration_ms", .{ .integer = @intCast(result.duration_ms) });
    try obj.put(allocator, "term", try commandTermValue(allocator, term));
    const stdout = try command_output.safeTextAlloc(allocator, result.stdout);
    const stderr = try command_output.safeTextAlloc(allocator, result.stderr);
    try command_output.putStreamFields(allocator, &obj, "stdout", stdout);
    try command_output.putStreamFields(allocator, &obj, "stderr", stderr);
    try obj.put(allocator, "stdout_truncated", .{ .bool = result.stdout_truncated });
    try obj.put(allocator, "stderr_truncated", .{ .bool = result.stderr_truncated });
    try obj.put(allocator, "stdout_limit", .{ .integer = @intCast(stdout_limit) });
    try obj.put(allocator, "stderr_limit", .{ .integer = @intCast(stderr_limit) });
    try obj.put(allocator, "output_limit_mode", .{ .string = command.output_limit_mode });
    try obj.put(allocator, "output_limit_exceeded", .{ .bool = result.stdout_truncated or result.stderr_truncated });
    if (result.stdout_truncated or result.stderr_truncated) {
        try obj.put(allocator, "note", .{ .string = "Command output exceeded zigar's capture limit. zigar returned the captured prefix and marked the truncated stream so the result remains inspectable." });
    }
    const insights = try command_result.compilerInsightsValue(allocator, stdout.text, stderr.text, argv);
    try obj.put(allocator, "diagnostics", insights);
    try obj.put(allocator, "failure_summary", try command_result.failureSummaryValue(allocator, insights, ok, argv));
    return .{ .object = obj };
}

pub fn commandErrorValue(allocator: std.mem.Allocator, title: []const u8, argv: []const []const u8, cwd: []const u8, timeout_ms: i64, err: ports.PortError) !std.json.Value {
    return command_result.commandErrorValue(allocator, title, argv, cwd, timeout_ms, err);
}
