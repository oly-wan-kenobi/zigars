const std = @import("std");

/// Process-local cancellation token visible to cooperative runtime work.
/// The token is intentionally small and borrowed; owners keep the backing state alive.
pub const Token = struct {
    ptr: ?*anyopaque = null,
    vtable: ?*const VTable = null,

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

    /// Returns the cancellation reason, or an empty string when none exists.
    pub fn reason(self: Token) []const u8 {
        const vtable = self.vtable orelse return "";
        const ptr = self.ptr orelse return "";
        return vtable.reason(ptr);
    }
};

/// Mutable backing state for one request-scoped cancellation token.
pub const State = struct {
    requested: bool = false,
    reason_buf: [160]u8 = [_]u8{0} ** 160,
    reason_len: usize = 0,

    /// Projects this state as a borrowed token.
    pub fn token(self: *State) Token {
        return .{
            .ptr = self,
            .vtable = &.{
                .is_cancelled = isCancelled,
                .reason = reason,
            },
        };
    }

    /// Marks the request as cancelled, retaining a bounded reason string.
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
