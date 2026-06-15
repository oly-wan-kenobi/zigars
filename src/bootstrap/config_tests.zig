//! Pins config parsing: defaults, explicit flags, allocation cleanup, HTTP loopback safety,
//! audit log options, empty flag rejection, and exit-code flags (help/version/unknown).
const std = @import("std");
const subject = @import("config.zig");
const Transport = subject.Transport;
const Config = subject.Config;
const ToolProfile = subject.ToolProfile;
const ParseError = subject.ParseError;
const parse = subject.parse;
const isLoopbackHttpHost = subject.isLoopbackHttpHost;
const usage = subject.usage;

test "parse defaults to cwd workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), std.testing.io, &.{"zigars"});
    try std.testing.expect(cfg.workspace.len > 0);
    try std.testing.expectEqual(Transport.stdio, cfg.transport);
}
test "parse explicit options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--workspace",
        "/tmp/project",
        "--transport",
        "http",
        "--port",
        "9090",
        "--timeout-ms",
        "5",
        "--zls-timeout-ms",
        "7",
        "--audit-log",
        ".zigars-cache/audit.jsonl",
        "--audit-log-mode",
        "redacted",
    });
    try std.testing.expectEqualStrings("/tmp/project", cfg.workspace);
    try std.testing.expectEqual(Transport.http, cfg.transport);
    try std.testing.expectEqual(@as(u16, 9090), cfg.port);
    try std.testing.expectEqual(@as(i64, 5), cfg.timeout_ms);
    try std.testing.expectEqual(@as(i64, 7), cfg.zls_timeout_ms);
    try std.testing.expectEqualStrings(".zigars-cache/audit.jsonl", cfg.audit_log_path.?);
    try std.testing.expectEqual(.redacted, cfg.audit_log_mode);
}
test "parse result can be deinitialized with general allocator" {
    var cfg = try parse(std.testing.allocator, std.testing.io, &.{
        "zigars",
        "--workspace",
        "/tmp/project",
        "--zig-path",
        "/opt/zig",
        "--cache-dir",
        ".zigars-cache",
    });
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/opt/zig", cfg.zig_path);
    try std.testing.expectEqualStrings(".zigars-cache", cfg.cache_dir.?);
    try std.testing.expect(cfg.audit_log_path == null);
    try std.testing.expectEqual(.metadata, cfg.audit_log_mode);
}

test "parse audit log defaults to metadata and rejects invalid audit inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cfg = try parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--audit-log",
        ".zigars-cache/audit.jsonl",
    });
    try std.testing.expectEqualStrings(".zigars-cache/audit.jsonl", cfg.audit_log_path.?);
    try std.testing.expectEqual(.metadata, cfg.audit_log_mode);

    try std.testing.expectError(ParseError.InvalidAuditLogMode, parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--audit-log-mode",
        "raw",
    }));
    try std.testing.expectError(ParseError.InvalidAuditLogPath, parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--audit-log",
        "",
    }));
    const full = try parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--audit-log",
        ".zigars-cache/full-audit.jsonl",
        "--audit-log-mode",
        "full",
    });
    try std.testing.expectEqual(.full, full.audit_log_mode);
}
test "parse selects tool profile and defaults to full" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const default_cfg = try parse(arena.allocator(), std.testing.io, &.{"zigars"});
    try std.testing.expectEqual(ToolProfile.full, default_cfg.profile);

    const core_cfg = try parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--profile",
        "core",
    });
    try std.testing.expectEqual(ToolProfile.core, core_cfg.profile);

    const full_cfg = try parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--profile",
        "full",
    });
    try std.testing.expectEqual(ToolProfile.full, full_cfg.profile);

    try std.testing.expectError(ParseError.InvalidProfile, parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--profile",
        "bogus",
    }));
    try std.testing.expectError(ParseError.MissingValue, parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--profile",
    }));
}
test "parse rejects empty path-like flag values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(ParseError.EmptyFlagValue, parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--zig-path",
        "",
    }));
    try std.testing.expectError(ParseError.EmptyFlagValue, parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--zls-path",
        "",
    }));
    try std.testing.expectError(ParseError.EmptyFlagValue, parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--workspace",
        "",
    }));
    try std.testing.expectError(ParseError.EmptyFlagValue, parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--cache-dir",
        "",
    }));

    // A non-empty path-like value still parses and is owned by the config.
    const cfg = try parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--zig-path",
        "/opt/zig",
    });
    try std.testing.expectEqualStrings("/opt/zig", cfg.zig_path);
}
test "parse rejects removed strict workspace flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ParseError.UnknownArgument, parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--strict-workspace",
    }));
}
test "parse accepts loopback http hosts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const hosts = [_][]const u8{ "127.0.0.1", "localhost", "::1", "[::1]" };
    for (hosts) |host| {
        const cfg = try parse(arena.allocator(), std.testing.io, &.{
            "zigars",
            "--transport",
            "http",
            "--host",
            host,
        });
        try std.testing.expectEqual(Transport.http, cfg.transport);
        try std.testing.expectEqualStrings(host, cfg.host);
    }
}
test "parse rejects non-loopback http hosts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ParseError.UnsafeHttpHost, parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--transport",
        "http",
        "--host",
        "0.0.0.0",
    }));
    try std.testing.expectError(ParseError.UnsafeHttpHost, parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--host",
        "192.168.1.20",
        "--transport",
        "http",
    }));
}
test "parse allows unused non-loopback host for stdio" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), std.testing.io, &.{
        "zigars",
        "--transport",
        "stdio",
        "--host",
        "0.0.0.0",
    });
    try std.testing.expectEqual(Transport.stdio, cfg.transport);
    try std.testing.expectEqualStrings("0.0.0.0", cfg.host);
}
test "parse defaults clean partial allocations on failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseDefaultsWithAllocator, .{});
}

/// Parses defaults with allocator input using caller-provided storage; malformed input and allocation failures propagate.
fn parseDefaultsWithAllocator(allocator: std.mem.Allocator) !void {
    var cfg = try parse(allocator, std.testing.io, &.{"zigars"});
    defer cfg.deinit(allocator);
}
