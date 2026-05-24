const std = @import("std");

pub const Transport = enum {
    stdio,
    http,
};

pub const Config = struct {
    workspace: []const u8,
    zig_path: []const u8 = "zig",
    zls_path: []const u8 = "zls",
    zlint_path: []const u8 = "zlint",
    zwanzig_path: []const u8 = "zwanzig",
    zflame_path: []const u8 = "zflame",
    diff_folded_path: []const u8 = "diff-folded",
    transport: Transport = .stdio,
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    cache_dir: ?[]const u8 = null,
    timeout_ms: i64 = 30_000,
    zls_timeout_ms: i64 = 30_000,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.workspace);
        allocator.free(self.zig_path);
        allocator.free(self.zls_path);
        allocator.free(self.zlint_path);
        allocator.free(self.zwanzig_path);
        allocator.free(self.zflame_path);
        allocator.free(self.diff_folded_path);
        allocator.free(self.host);
        if (self.cache_dir) |cache_dir| allocator.free(cache_dir);
        self.* = undefined;
    }
};

pub const ParseError = error{
    HelpRequested,
    VersionRequested,
    MissingValue,
    UnknownArgument,
    InvalidPort,
    InvalidTimeout,
    InvalidTransport,
    UnsafeHttpHost,
};

pub fn parse(allocator: std.mem.Allocator, io: std.Io, raw_args: []const []const u8) !Config {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io, &cwd_buf);
    const cwd = cwd_buf[0..cwd_len];
    var result = try ownedDefaults(allocator, cwd);
    errdefer result.deinit(allocator);

    var i: usize = 1;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return ParseError.HelpRequested;
        if (std.mem.eql(u8, arg, "--version")) return ParseError.VersionRequested;

        if (std.mem.eql(u8, arg, "--workspace")) {
            try replaceOwned(allocator, &result.workspace, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--zig-path")) {
            try replaceOwned(allocator, &result.zig_path, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--zls-path")) {
            try replaceOwned(allocator, &result.zls_path, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--zlint-path")) {
            try replaceOwned(allocator, &result.zlint_path, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--zwanzig-path")) {
            try replaceOwned(allocator, &result.zwanzig_path, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--zflame-path")) {
            try replaceOwned(allocator, &result.zflame_path, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--diff-folded-path")) {
            try replaceOwned(allocator, &result.diff_folded_path, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--host")) {
            try replaceOwned(allocator, &result.host, raw_args, &i);
        } else if (std.mem.eql(u8, arg, "--cache-dir")) {
            const value = try dupeNext(allocator, raw_args, &i);
            if (result.cache_dir) |old| allocator.free(old);
            result.cache_dir = value;
        } else if (std.mem.eql(u8, arg, "--transport")) {
            const value = try dupeNext(allocator, raw_args, &i);
            defer allocator.free(value);
            if (std.mem.eql(u8, value, "stdio")) {
                result.transport = .stdio;
            } else if (std.mem.eql(u8, value, "http")) {
                result.transport = .http;
            } else {
                return ParseError.InvalidTransport;
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            const value = try dupeNext(allocator, raw_args, &i);
            defer allocator.free(value);
            result.port = std.fmt.parseInt(u16, value, 10) catch return ParseError.InvalidPort;
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            const value = try dupeNext(allocator, raw_args, &i);
            defer allocator.free(value);
            result.timeout_ms = std.fmt.parseInt(i64, value, 10) catch return ParseError.InvalidTimeout;
            if (result.timeout_ms <= 0) return ParseError.InvalidTimeout;
        } else if (std.mem.eql(u8, arg, "--zls-timeout-ms")) {
            const value = try dupeNext(allocator, raw_args, &i);
            defer allocator.free(value);
            result.zls_timeout_ms = std.fmt.parseInt(i64, value, 10) catch return ParseError.InvalidTimeout;
            if (result.zls_timeout_ms <= 0) return ParseError.InvalidTimeout;
        } else {
            return ParseError.UnknownArgument;
        }
    }

    if (result.transport == .http and !isLoopbackHttpHost(result.host)) return ParseError.UnsafeHttpHost;
    return result;
}

pub fn isLoopbackHttpHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "[::1]") or
        std.ascii.eqlIgnoreCase(host, "localhost");
}

fn ownedDefaults(allocator: std.mem.Allocator, cwd: []const u8) !Config {
    const workspace = try allocator.dupe(u8, cwd);
    errdefer allocator.free(workspace);
    const zig_path = try allocator.dupe(u8, "zig");
    errdefer allocator.free(zig_path);
    const zls_path = try allocator.dupe(u8, "zls");
    errdefer allocator.free(zls_path);
    const zlint_path = try allocator.dupe(u8, "zlint");
    errdefer allocator.free(zlint_path);
    const zwanzig_path = try allocator.dupe(u8, "zwanzig");
    errdefer allocator.free(zwanzig_path);
    const zflame_path = try allocator.dupe(u8, "zflame");
    errdefer allocator.free(zflame_path);
    const diff_folded_path = try allocator.dupe(u8, "diff-folded");
    errdefer allocator.free(diff_folded_path);
    const host = try allocator.dupe(u8, "127.0.0.1");
    errdefer allocator.free(host);

    return .{
        .workspace = workspace,
        .zig_path = zig_path,
        .zls_path = zls_path,
        .zlint_path = zlint_path,
        .zwanzig_path = zwanzig_path,
        .zflame_path = zflame_path,
        .diff_folded_path = diff_folded_path,
        .host = host,
    };
}

fn replaceOwned(allocator: std.mem.Allocator, field: *[]const u8, args: []const []const u8, index: *usize) !void {
    const value = try dupeNext(allocator, args, index);
    allocator.free(field.*);
    field.* = value;
}

fn dupeNext(allocator: std.mem.Allocator, args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return ParseError.MissingValue;
    return allocator.dupe(u8, args[index.*]);
}

pub fn usage() []const u8 {
    return
    \\zigar - deterministic Zig development MCP server
    \\
    \\Usage:
    \\  zigar [--workspace <path>] [--zig-path <path>] [--zls-path <path>]
    \\        [--zlint-path <path>] [--zwanzig-path <path>] [--zflame-path <path>]
    \\        [--diff-folded-path <path>]
    \\        [--transport stdio|http] [--host 127.0.0.1|localhost|::1] [--port 8080]
    \\        [--cache-dir <path>] [--timeout-ms <n>] [--zls-timeout-ms <n>]
    \\
    \\stdio is the safest default for Codex. http is local-only and must bind loopback.
    \\stdout is reserved for MCP JSON-RPC. Logs, help, and version go to stderr.
    \\
    ;
}

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
