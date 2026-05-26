//! One-shot transport adapter that captures a single JSON-RPC response for HTTP POST handling.
const std = @import("std");
const mcp = @import("mcp");

const transport_mod = mcp.transport;

/// Transport implementation that stores the last sent response for HTTP reply.
pub const HttpRequestTransport = struct {
    // Owned serialized JSON response returned to the HTTP layer.
    response_message: ?[]const u8 = null,
    is_closed: bool = false,

    const Self = @This();

    /// Frees any captured response message.
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.response_message) |msg| {
            allocator.free(msg);
            self.response_message = null;
        }
    }

    /// Captures an owned copy of the serialized JSON-RPC response.
    pub fn send(self: *Self, _: std.Io, allocator: std.mem.Allocator, message: []const u8) transport_mod.Transport.SendError!void {
        if (self.is_closed) return transport_mod.Transport.SendError.ConnectionClosed;

        const owned = allocator.dupe(u8, message) catch return transport_mod.Transport.SendError.OutOfMemory;
        if (self.response_message) |old| {
            allocator.free(old);
        }
        self.response_message = owned;
    }

    /// Receive is unused for one-shot HTTP requests and returns no message.
    pub fn receive(self: *Self, _: std.Io, _: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
        if (self.is_closed) return transport_mod.Transport.ReceiveError.ConnectionClosed;
        return null;
    }

    /// Marks the request transport closed.
    pub fn close(self: *Self) void {
        self.is_closed = true;
    }

    /// Exposes this object through the generic MCP transport vtable.
    pub fn transport(self: *Self) transport_mod.Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = sendVtable,
                .receive = receiveVtable,
                .close = closeVtable,
            },
        };
    }

    fn sendVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator, message: []const u8) transport_mod.Transport.SendError!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.send(io, allocator, message);
    }

    fn receiveVtable(ptr: *anyopaque, io: std.Io, allocator: std.mem.Allocator) transport_mod.Transport.ReceiveError!?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.receive(io, allocator);
    }

    fn closeVtable(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.close();
    }
};
