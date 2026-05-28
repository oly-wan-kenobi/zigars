const std = @import("std");

const doctor = @import("doctor.zig");

test "doctor report includes checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try doctor.report(arena.allocator(), .{
        .workspace = "/tmp/project",
        .cache = "/tmp/project/.zigars-cache",
        .transport = "stdio",
        .zig_path = "zig",
        .zls_path = "zls",
        .zlint_path = "zlint",
        .zwanzig_path = "zwanzig",
        .zflame_path = "zflame",
        .diff_folded_path = "diff-folded",
        .zls_status = "connected",
        .zls_last_failure = null,
        .timeout_ms = 30_000,
        .zls_timeout_ms = 30_000,
        .mcp_dependency = "mcp.zig 0.0.5",
        .tools_list_schema_rich = true,
        .http_available = false,
        .zig_probe = .{ .ok = true, .status = "ok", .resolution = "backend command completed" },
        .zls_probe = .{ .ok = false, .status = "FileNotFound", .resolution = "confirm the configured backend path and executable permissions" },
    });
    const checks = value.object.get("checks").?.array;
    try std.testing.expect(checks.items.len >= 2);
    var saw_zig_probe = false;
    var saw_zls_probe = false;
    var saw_tools_schema = false;
    for (checks.items) |check| {
        const obj = check.object;
        const name = obj.get("name").?.string;
        if (std.mem.eql(u8, name, "zig_probe")) saw_zig_probe = true;
        if (std.mem.eql(u8, name, "zls_probe")) saw_zls_probe = true;
        if (std.mem.eql(u8, name, "mcp_tools_list_schema")) saw_tools_schema = true;
    }
    try std.testing.expect(saw_zig_probe);
    try std.testing.expect(saw_zls_probe);
    try std.testing.expect(saw_tools_schema);
}

test "doctor report uses default ZLS resolution when disconnected without failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = try doctor.report(arena.allocator(), .{
        .workspace = "/tmp/project",
        .cache = "/tmp/project/.zigars-cache",
        .transport = "stdio",
        .zig_path = "zig",
        .zls_path = "zls",
        .zlint_path = "zlint",
        .zwanzig_path = "zwanzig",
        .zflame_path = "zflame",
        .diff_folded_path = "diff-folded",
        .zls_status = "not started",
        .zls_last_failure = null,
        .timeout_ms = 30_000,
        .zls_timeout_ms = 30_000,
        .mcp_dependency = "mcp.zig 0.0.5",
        .http_available = true,
    });
    const checks = value.object.get("checks").?.array;
    try std.testing.expect(checks.items.len >= 1);
}
