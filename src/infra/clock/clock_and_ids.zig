const std = @import("std");

const ports = @import("../../app/ports.zig");

pub const RuntimeClockAndIds = struct {
    io: std.Io,
    counter: *std.atomic.Value(u64),

    const Self = @This();

    pub fn init(io: std.Io, counter: *std.atomic.Value(u64)) Self {
        return .{
            .io = io,
            .counter = counter,
        };
    }

    pub fn port(self: *Self) ports.ClockAndIds {
        return .{
            .ptr = self,
            .vtable = &.{
                .now = now,
                .nextId = nextId,
            },
        };
    }

    fn now(ptr: *anyopaque) ports.PortError!ports.Instant {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return .{
            .unix_ms = @intCast(@divTrunc(std.Io.Clock.now(.real, self.io).nanoseconds, std.time.ns_per_ms)),
            .monotonic_ms = 0,
        };
    }

    fn nextId(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.IdRequest) ports.PortError![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const id = self.counter.fetchAdd(1, .monotonic);
        return std.fmt.allocPrint(allocator, "{s}{d}", .{ request.prefix, id });
    }
};

test "runtime clock and ids use process clock and monotonic counter" {
    var counter = std.atomic.Value(u64).init(7);
    var clock = RuntimeClockAndIds.init(std.testing.io, &counter);

    const instant = try clock.port().now();
    try std.testing.expect(instant.unix_ms > 0);
    try std.testing.expectEqual(@as(u64, 0), instant.monotonic_ms);

    const id = try clock.port().nextId(std.testing.allocator, .{ .prefix = "tmp-" });
    defer std.testing.allocator.free(id);
    try std.testing.expectEqualStrings("tmp-7", id);
    try std.testing.expectEqual(@as(u64, 8), counter.load(.monotonic));
}
