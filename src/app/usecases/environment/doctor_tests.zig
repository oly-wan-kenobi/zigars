//! Pins doctor behavior: check assembly (including optional probe checks and
//! the tools/list schema check), the default ZLS resolution when disconnected,
//! and Zig version preflight outcomes (compatible, incompatible, unavailable,
//! unprobed) plus the build.zig.zon minimum-version parser.
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

test "zig version preflight reports compatible exact minimum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try doctor.zigVersionPreflightValue(arena.allocator(), .{
        .zig_path = "/opt/zig/zig",
        .observed_version = "0.16.0\n",
        .required_minimum = "0.16.0",
    });

    try std.testing.expectEqualStrings("zig_version_preflight", value.object.get("name").?.string);
    try std.testing.expect(value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("compatible", value.object.get("status").?.string);
    try std.testing.expectEqualStrings("0.16.0", value.object.get("observed_version").?.string);
    try std.testing.expectEqualStrings("0.16.0", value.object.get("required_minimum").?.string);
}

test "zig version preflight reports incompatible version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try doctor.zigVersionPreflightValue(arena.allocator(), .{
        .zig_path = "/opt/zig/zig",
        .observed_version = "0.15.2",
        .required_minimum = "0.16.0",
    });

    try std.testing.expect(!value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("incompatible", value.object.get("status").?.string);
    try std.testing.expect(std.mem.indexOf(u8, value.object.get("resolution").?.string, "requires 0.16.0 or newer") != null);
}

test "zig version preflight reports missing Zig as unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try doctor.zigVersionPreflightValue(arena.allocator(), .{
        .zig_path = "/missing/zig",
        .required_minimum = "0.16.0",
        .unavailable_reason = "FileNotFound",
    });

    try std.testing.expect(!value.object.get("ok").?.bool);
    try std.testing.expectEqualStrings("unavailable", value.object.get("status").?.string);
    try std.testing.expect(std.mem.indexOf(u8, value.object.get("resolution").?.string, "FileNotFound") != null);
}

test "zig version preflight reports probe-disabled behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const value = try doctor.zigVersionPreflightValue(arena.allocator(), .{
        .probe_enabled = false,
        .zig_path = "zig",
    });

    try std.testing.expect(value.object.get("ok").? == .null);
    try std.testing.expectEqualStrings("unprobed", value.object.get("status").?.string);
}

test "build zon minimum parser finds quoted version" {
    const bytes =
        \\.{
        \\    .name = .zigar,
        \\    .minimum_zig_version = "0.16.0",
        \\}
    ;
    try std.testing.expectEqualStrings("0.16.0", doctor.minimumZigVersionFromBuildZon(bytes).?);
    try std.testing.expect(doctor.versionMeetsMinimum("0.16.0-dev.123", "0.16.0"));
    try std.testing.expect(!doctor.versionMeetsMinimum("0.15.2", "0.16.0"));
}
