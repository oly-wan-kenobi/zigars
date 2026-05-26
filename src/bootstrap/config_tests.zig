const std = @import("std");
const subject = @import("config.zig");
const Transport = subject.Transport;
const Config = subject.Config;
const ParseError = subject.ParseError;
const parse = subject.parse;
const isLoopbackHttpHost = subject.isLoopbackHttpHost;
const usage = subject.usage;

test "parse defaults to cwd workspace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), std.testing.io, &.{"zigar"});
    try std.testing.expect(cfg.workspace.len > 0);
    try std.testing.expectEqual(Transport.stdio, cfg.transport);
}
test "parse explicit options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parse(arena.allocator(), std.testing.io, &.{
        "zigar",
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
    });
    try std.testing.expectEqualStrings("/tmp/project", cfg.workspace);
    try std.testing.expectEqual(Transport.http, cfg.transport);
    try std.testing.expectEqual(@as(u16, 9090), cfg.port);
    try std.testing.expectEqual(@as(i64, 5), cfg.timeout_ms);
    try std.testing.expectEqual(@as(i64, 7), cfg.zls_timeout_ms);
}
test "parse result can be deinitialized with general allocator" {
    var cfg = try parse(std.testing.allocator, std.testing.io, &.{
        "zigar",
        "--workspace",
        "/tmp/project",
        "--zig-path",
        "/opt/zig",
        "--cache-dir",
        ".zigar-cache",
    });
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/opt/zig", cfg.zig_path);
    try std.testing.expectEqualStrings(".zigar-cache", cfg.cache_dir.?);
}
test "parse rejects removed strict workspace flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(ParseError.UnknownArgument, parse(arena.allocator(), std.testing.io, &.{
        "zigar",
        "--strict-workspace",
    }));
}
test "parse accepts loopback http hosts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const hosts = [_][]const u8{ "127.0.0.1", "localhost", "::1", "[::1]" };
    for (hosts) |host| {
        const cfg = try parse(arena.allocator(), std.testing.io, &.{
            "zigar",
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
        "zigar",
        "--transport",
        "http",
        "--host",
        "0.0.0.0",
    }));
    try std.testing.expectError(ParseError.UnsafeHttpHost, parse(arena.allocator(), std.testing.io, &.{
        "zigar",
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
        "zigar",
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

fn parseDefaultsWithAllocator(allocator: std.mem.Allocator) !void {
    var cfg = try parse(allocator, std.testing.io, &.{"zigar"});
    defer cfg.deinit(allocator);
}
