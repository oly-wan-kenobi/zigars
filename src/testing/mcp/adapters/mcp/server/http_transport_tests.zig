//! Pins the HTTP request transport contract: each send overwrites the previous
//! response (request/response lifecycle), receive returns null (HTTP is
//! request-driven), and post-close sends/receives return ConnectionClosed.

const std = @import("std");
const mcp = @import("mcp");

const HttpRequestTransport = @import("../../../../../adapters/mcp/server/http_transport.zig").HttpRequestTransport;
const transport_mod = mcp.transport;

test "http request transport captures the latest response and releases the old one" {
    var transport = HttpRequestTransport{};
    defer transport.deinit(std.testing.allocator);

    try transport.send(std.testing.io, std.testing.allocator, "first");
    try std.testing.expectEqualStrings("first", transport.response_message.?);
    try transport.send(std.testing.io, std.testing.allocator, "second");
    try std.testing.expectEqualStrings("second", transport.response_message.?);
}

test "http request transport vtable handles receive and close states" {
    var transport = HttpRequestTransport{};
    defer transport.deinit(std.testing.allocator);

    const tx = transport.transport();
    try tx.vtable.send(tx.ptr, std.testing.io, std.testing.allocator, "response");
    try std.testing.expect((try tx.vtable.receive(tx.ptr, std.testing.io, std.testing.allocator)) == null);
    tx.vtable.close(tx.ptr);
    try std.testing.expect(transport.is_closed);
    try std.testing.expectError(transport_mod.Transport.SendError.ConnectionClosed, tx.vtable.send(tx.ptr, std.testing.io, std.testing.allocator, "late"));
    try std.testing.expectError(transport_mod.Transport.ReceiveError.ConnectionClosed, tx.vtable.receive(tx.ptr, std.testing.io, std.testing.allocator));
}
