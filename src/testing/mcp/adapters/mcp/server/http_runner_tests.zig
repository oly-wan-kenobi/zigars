const std = @import("std");
const http = std.http;

const http_runner = @import("../../../../../adapters/mcp/server/http_runner.zig");

const TestAccess = http_runner.TestAccess;

test "non-loopback bind is refused without explicit opt-in (MEDIUM-3)" {
    // 0.0.0.0 / public IPs are non-loopback; without the opt-in the bind is
    // refused (serve returns error.NonLoopbackBindRefused before any socket).
    try std.testing.expect(http_runner.bindRefused(.{ .host = "0.0.0.0", .port = 8080 }));
    try std.testing.expect(http_runner.bindRefused(.{ .host = "203.0.113.5", .port = 8080 }));
    // The explicit opt-in allows the non-loopback bind.
    try std.testing.expect(!http_runner.bindRefused(.{ .host = "0.0.0.0", .port = 8080, .allow_non_loopback_bind = true }));
    // Loopback hosts are never refused, with or without the opt-in.
    try std.testing.expect(!http_runner.bindRefused(.{ .host = "127.0.0.1", .port = 8080 }));
    try std.testing.expect(!http_runner.bindRefused(.{ .host = "localhost", .port = 8080 }));
    try std.testing.expect(!http_runner.bindRefused(.{ .host = "::1", .port = 8080 }));
    // localhost resolves to the loopback IPv4 literal for binding.
    try std.testing.expectEqualStrings("127.0.0.1", http_runner.bindHostFor(.{ .host = "localhost" }));
    try std.testing.expectEqualStrings("0.0.0.0", http_runner.bindHostFor(.{ .host = "0.0.0.0" }));
}

test "loopback host classification covers ipv4 ipv6 and localhost" {
    try std.testing.expect(TestAccess.isLoopbackHost("127.0.0.1"));
    try std.testing.expect(TestAccess.isLoopbackHost("::1"));
    try std.testing.expect(TestAccess.isLoopbackHost("[::1]"));
    try std.testing.expect(TestAccess.isLoopbackHost("localhost"));
    try std.testing.expect(TestAccess.isLoopbackHost("LOCALHOST"));
    try std.testing.expect(!TestAccess.isLoopbackHost("0.0.0.0"));
    try std.testing.expect(!TestAccess.isLoopbackHost("192.168.1.10"));
    try std.testing.expect(!TestAccess.isLoopbackHost("evil.example.com"));
}

test "host and origin loopback parsing strips ports and schemes" {
    try std.testing.expectEqualStrings("127.0.0.1", TestAccess.hostWithoutPort("127.0.0.1:8080"));
    try std.testing.expectEqualStrings("[::1]", TestAccess.hostWithoutPort("[::1]:8080"));
    try std.testing.expectEqualStrings("localhost", TestAccess.hostWithoutPort("localhost"));

    try std.testing.expect(TestAccess.hostHeaderIsLoopback("127.0.0.1:8080"));
    try std.testing.expect(TestAccess.hostHeaderIsLoopback("localhost:8080"));
    try std.testing.expect(!TestAccess.hostHeaderIsLoopback("attacker.example.com:8080"));

    try std.testing.expect(TestAccess.originIsLoopback("http://127.0.0.1:8080"));
    try std.testing.expect(TestAccess.originIsLoopback("https://localhost"));
    try std.testing.expect(!TestAccess.originIsLoopback("http://attacker.example.com"));
    // The opaque "null" origin (sandboxed/file pages) is rejected.
    try std.testing.expect(!TestAccess.originIsLoopback("null"));
}

/// Builds a `Request` over fixed header bytes, mirroring std's own
/// `iterateHeaders` test harness, so the Origin/Host gate can be exercised
/// without a live socket.
fn requestFromHeadBytes(server: *http.Server, head_bytes: []const u8) http.Server.Request {
    return .{
        .server = server,
        .head = undefined,
        .head_buffer = @constCast(head_bytes),
    };
}

fn receivedHeadServer() http.Server {
    return .{
        .reader = .{
            .in = undefined,
            .state = .received_head,
            .interface = undefined,
            .max_head_len = 4096,
        },
        .out = undefined,
    };
}

test "origin/host gate accepts loopback and rejects cross-origin (DNS rebinding)" {
    var server = receivedHeadServer();

    // No Origin, loopback Host: allowed (non-browser MCP host clients).
    {
        var request = requestFromHeadBytes(&server, "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n");
        try std.testing.expect(TestAccess.originAndHostAllowed(&request));
    }
    // Loopback Origin and Host: allowed.
    {
        var request = requestFromHeadBytes(&server, "POST /mcp HTTP/1.1\r\nHost: localhost:8080\r\nOrigin: http://localhost:8080\r\n\r\n");
        try std.testing.expect(TestAccess.originAndHostAllowed(&request));
    }
    // Cross-origin (attacker page rebinding to loopback): rejected on Origin.
    {
        var request = requestFromHeadBytes(&server, "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nOrigin: http://attacker.example.com\r\n\r\n");
        try std.testing.expect(!TestAccess.originAndHostAllowed(&request));
    }
    // Rebound Host header (non-loopback): rejected on Host.
    {
        var request = requestFromHeadBytes(&server, "POST /mcp HTTP/1.1\r\nHost: attacker.example.com\r\n\r\n");
        try std.testing.expect(!TestAccess.originAndHostAllowed(&request));
    }
    // No headers at all: allowed (nothing to reject).
    {
        var request = requestFromHeadBytes(&server, "POST /mcp HTTP/1.1\r\n\r\n");
        try std.testing.expect(TestAccess.originAndHostAllowed(&request));
    }
}
