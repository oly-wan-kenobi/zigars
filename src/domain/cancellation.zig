//! Cooperative cancellation primitives for request-scoped runtime work.
//! Callers check Token.isCancelled at yield points; no thread signaling is used.

const std = @import("std");

/// Process-local cancellation token visible to cooperative runtime work.
/// The token is intentionally small and borrowed; the owner (State) must outlive
/// every copy of the token derived from it.
pub const Token = struct {
    ptr: ?*anyopaque = null,
    vtable: ?*const VTable = null,

    /// VTable interface; implementations must be thread-safe if the token
    /// crosses thread boundaries, though the built-in State is not.
    pub const VTable = struct {
        is_cancelled: *const fn (*anyopaque) bool,
        reason: *const fn (*anyopaque) []const u8,
    };

    /// Returns true when cancellation has been requested.
    pub fn isCancelled(self: Token) bool {
        const vtable = self.vtable orelse return false;
        const ptr = self.ptr orelse return false;
        return vtable.is_cancelled(ptr);
    }

    /// Returns the cancellation reason, or an empty string when none was set.
    /// The returned slice is valid only while the backing State is alive.
    pub fn reason(self: Token) []const u8 {
        const vtable = self.vtable orelse return "";
        const ptr = self.ptr orelse return "";
        return vtable.reason(ptr);
    }
};

/// Mutable backing state for one request-scoped cancellation token.
/// Allocated on the stack by the request handler; the token() projection is passed
/// to workers. reason_buf is fixed-size to avoid allocation on the cancellation path.
pub const State = struct {
    requested: bool = false,
    // 160 bytes covers typical MCP cancellation reason strings without heap allocation.
    reason_buf: [160]u8 = [_]u8{0} ** 160,
    reason_len: usize = 0,

    /// Projects this state as a borrowed token.
    /// The token must not outlive this State instance.
    pub fn token(self: *State) Token {
        // Keep this logic centralized so callers observe one consistent behavior path.
        return .{
            .ptr = self,
            .vtable = &.{
                .is_cancelled = isCancelled,
                .reason = reason,
            },
        };
    }

    /// Marks the request as cancelled, retaining a bounded reason string.
    /// Excess bytes beyond reason_buf capacity are silently truncated.
    /// Once requested, the flag is never cleared; cancellation is one-way.
    pub fn request(self: *State, value: []const u8) void {
        self.requested = true;
        const copy_len = @min(value.len, self.reason_buf.len);
        @memcpy(self.reason_buf[0..copy_len], value[0..copy_len]);
        self.reason_len = copy_len;
    }

    fn isCancelled(ptr: *anyopaque) bool {
        const self: *State = @ptrCast(@alignCast(ptr));
        return self.requested;
    }

    fn reason(ptr: *anyopaque) []const u8 {
        const self: *State = @ptrCast(@alignCast(ptr));
        return self.reason_buf[0..self.reason_len];
    }
};

test "cancellation token reports bounded reason" {
    var state = State{};
    const token_value = state.token();
    try std.testing.expect(!token_value.isCancelled());
    state.request("client requested cancellation");
    try std.testing.expect(token_value.isCancelled());
    try std.testing.expectEqualStrings("client requested cancellation", token_value.reason());
}
