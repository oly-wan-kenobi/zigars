const std = @import("std");

const ports = @import("../../app/ports.zig");

/// ClockAndIds port backed by the process clock and an atomic counter.
pub const RuntimeClockAndIds = struct {
    io: std.Io,
    counter: *std.atomic.Value(u64),

    const Self = @This();

    /// Stores a borrowed counter used to generate deterministic monotonic IDs.
    pub fn init(io: std.Io, counter: *std.atomic.Value(u64)) Self {
        return .{
            .io = io,
            .counter = counter,
        };
    }

    /// Exposes this clock through the ClockAndIds vtable.
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
