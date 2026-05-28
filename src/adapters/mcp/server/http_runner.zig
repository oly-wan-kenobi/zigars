//! Built-in local HTTP transport runner for one-request JSON-RPC POSTs.
const std = @import("std");
const http = std.http;

const HttpRequestTransport = @import("http_transport.zig").HttpRequestTransport;

/// Maximum accepted JSON-RPC POST body size for the built-in HTTP transport.
pub const max_body_size: usize = 4 * 1024 * 1024;

/// Options for running the HTTP server.
pub const RunConfig = struct {
    port: u16 = 8080,
    host: []const u8 = "localhost",
};

/// Accepts sequential HTTP connections and routes each POST as one JSON-RPC message.
pub fn run(server: anytype, io: std.Io, allocator: std.mem.Allocator, config: RunConfig) !void {
    const bind_host = if (std.mem.eql(u8, config.host, "localhost")) "127.0.0.1" else config.host;

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

    try handleJsonRpcRequest(server, io, allocator, &request);
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
