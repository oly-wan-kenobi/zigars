//! Built-in local HTTP transport runner for one-request JSON-RPC POSTs.
const std = @import("std");
const http = std.http;

const HttpRequestTransport = @import("http_transport.zig").HttpRequestTransport;

/// Maximum accepted JSON-RPC POST body size for the built-in HTTP transport.
pub const max_body_size: usize = 4 * 1024 * 1024;

/// Options for running the HTTP server.
///
/// The built-in HTTP transport is loopback-only by design: it has no
/// authentication, so it must never be exposed to a network. `host` defaults to
/// `localhost` (resolved to `127.0.0.1`). Binding any non-loopback address
/// requires `allow_non_loopback_bind = true`, an explicit operator opt-in that
/// acknowledges the unauthenticated exposure.
pub const RunConfig = struct {
    port: u16 = 8080,
    host: []const u8 = "localhost",
    /// Opt-in escape hatch to bind a non-loopback host. Off by default so a
    /// misconfigured `host` (e.g. `0.0.0.0`) cannot silently expose the server.
    allow_non_loopback_bind: bool = false,
};

/// Resolves the literal host to bind from configuration (`localhost` -> the
/// loopback IPv4 literal so `resolve` cannot pick a non-loopback record).
pub fn bindHostFor(config: RunConfig) []const u8 {
    return if (std.mem.eql(u8, config.host, "localhost")) "127.0.0.1" else config.host;
}

/// Whether a bind must be refused: a non-loopback host without the explicit
/// opt-in. The built-in HTTP transport has no auth, so a non-loopback bind is a
/// network-exposure risk (MEDIUM-3); loopback-only is the default contract.
pub fn bindRefused(config: RunConfig) bool {
    return !isLoopbackHost(bindHostFor(config)) and !config.allow_non_loopback_bind;
}

/// Accepts sequential HTTP connections and routes each POST as one JSON-RPC message.
pub fn serve(server: anytype, io: std.Io, allocator: std.mem.Allocator, config: RunConfig) !void {
    if (bindRefused(config)) return error.NonLoopbackBindRefused;
    const bind_host = bindHostFor(config);

    const bind_started_ns = monotonicNowNs(io);
    const address = std.Io.net.IpAddress.resolve(io, bind_host, config.port) catch {
        return error.AddressResolutionError;
    };

    var listener = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer listener.deinit(io);
    server.transport_name = "http";
    server.recordStartupPhaseRange("transport_bind", bind_started_ns, monotonicNowNs(io));

    while (server.state != .stopped and server.state != .shutting_down) {
        const stream = try listener.accept(io);
        serveConnection(server, io, allocator, stream) catch |err| {
            std.log.err("HTTP connection error: {s}", .{@errorName(err)});
        };
    }
}

fn serveConnection(server: anytype, io: std.Io, allocator: std.mem.Allocator, stream: std.Io.net.Stream) !void {
    defer stream.close(io);

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var http_server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    var request = http_server.receiveHead() catch |err| switch (err) {
        error.HttpConnectionClosing => return,
        else => return err,
    };

    if (request.head.method != .POST) {
        try request.respond("Method Not Allowed", .{
            .status = .method_not_allowed,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    // DNS-rebinding defense (MEDIUM-3): even bound to loopback, a malicious web
    // page can POST JSON-RPC to 127.0.0.1:<port>. Reject any request whose
    // Origin or Host header is not loopback before dispatching a tool call.
    if (!originAndHostAllowed(&request)) {
        try request.respond("Forbidden: cross-origin or non-loopback Host/Origin rejected", .{
            .status = .forbidden,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    try handleJsonRpcRequest(server, io, allocator, &request);
}

/// Validates the request `Origin` and `Host` headers against a loopback
/// allowlist. An absent `Origin` is allowed (non-browser clients such as the
/// MCP host omit it); a present `Origin` must be loopback. `Host`, when present,
/// must also be loopback. This blocks DNS-rebinding: a rebound hostname yields a
/// non-loopback `Host`/`Origin` and is refused.
fn originAndHostAllowed(request: *const http.Server.Request) bool {
    var it = request.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "origin")) {
            if (!originIsLoopback(header.value)) return false;
        } else if (std.ascii.eqlIgnoreCase(header.name, "host")) {
            if (!hostHeaderIsLoopback(header.value)) return false;
        }
    }
    return true;
}

/// True when an `Origin` header value (`scheme://host[:port]`) names a loopback
/// host. A missing scheme separator is treated as a bare authority.
fn originIsLoopback(origin: []const u8) bool {
    // "null" is the opaque origin browsers send for sandboxed/file contexts.
    if (std.ascii.eqlIgnoreCase(origin, "null")) return false;
    const after_scheme = if (std.mem.indexOf(u8, origin, "://")) |idx| origin[idx + 3 ..] else origin;
    return hostHeaderIsLoopback(after_scheme);
}

/// True when a `Host`/authority value (`host[:port]`) names a loopback host.
fn hostHeaderIsLoopback(authority: []const u8) bool {
    return isLoopbackHost(hostWithoutPort(authority));
}

/// Strips an optional `:port` suffix from an authority, preserving bracketed
/// IPv6 literals (`[::1]:8080` -> `[::1]`).
fn hostWithoutPort(authority: []const u8) []const u8 {
    if (authority.len == 0) return authority;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return authority;
        return authority[0 .. close + 1];
    }
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |idx| return authority[0..idx];
    return authority;
}

/// True only for loopback hosts the built-in HTTP transport may bind or accept.
fn isLoopbackHost(host: []const u8) bool {
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.mem.eql(u8, host, "::1") or
        std.mem.eql(u8, host, "[::1]") or
        std.ascii.eqlIgnoreCase(host, "localhost");
}

fn handleJsonRpcRequest(server: anytype, io: std.Io, allocator: std.mem.Allocator, request: *http.Server.Request) !void {
    const content_length = request.head.content_length orelse {
        try request.respond("Content-Length required", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    };

    if (content_length == 0) {
        try request.respond("Empty JSON-RPC payload", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    if (content_length > max_body_size) {
        try request.respond("Request body too large", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    }

    var read_buffer: [2048]u8 = undefined;
    var body_reader = try request.readerExpectContinue(&read_buffer);

    const read_len: usize = @intCast(content_length);

    const body_items = body_reader.readAlloc(allocator, read_len) catch {
        try request.respond("Failed to read request body", .{
            .status = .bad_request,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
        return;
    };
    defer allocator.free(body_items);

    var request_transport: HttpRequestTransport = .{};
    defer request_transport.deinit(allocator);

    const previous_transport = server.transport;
    server.transport = request_transport.transport();
    defer server.transport = previous_transport;

    try server.handleMessage(io, allocator, body_items);

    if (request_transport.response_message) |response_json| {
        try request.respond(response_json, .{
            .status = .ok,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
        return;
    }

    try request.respond("", .{ .status = .no_content });
}

fn monotonicNowNs(io: std.Io) i128 {
    return std.Io.Clock.now(.awake, io).nanoseconds;
}

/// Test-only access to the loopback/Origin/Host gate so the MEDIUM-3 defenses
/// can be exercised without a live socket. Kept out of the production surface.
pub const TestAccess = struct {
    pub fn originAndHostAllowed(request: *const http.Server.Request) bool {
        return @import("http_runner.zig").originAndHostAllowed(request);
    }

    pub fn isLoopbackHost(host: []const u8) bool {
        return @import("http_runner.zig").isLoopbackHost(host);
    }

    pub fn originIsLoopback(origin: []const u8) bool {
        return @import("http_runner.zig").originIsLoopback(origin);
    }

    pub fn hostHeaderIsLoopback(authority: []const u8) bool {
        return @import("http_runner.zig").hostHeaderIsLoopback(authority);
    }

    pub fn hostWithoutPort(authority: []const u8) []const u8 {
        return @import("http_runner.zig").hostWithoutPort(authority);
    }
};
