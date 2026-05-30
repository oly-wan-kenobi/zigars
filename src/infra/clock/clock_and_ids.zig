//! Runtime implementation of the ClockAndIds port.
//! IDs are deterministic and monotonically increasing: the counter is an
//! external atomic so the caller controls the ID sequence and can reset it
//! in tests to produce stable, predictable values.

const std = @import("std");

const ports = @import("../../app/ports.zig");

/// ClockAndIds port backed by the process clock and an atomic counter.
pub const RuntimeClockAndIds = struct {
    io: std.Io,
    counter: *std.atomic.Value(u64),

    const Self = @This();

    /// Stores a borrowed counter used to generate deterministic monotonic IDs.
    /// Both `io` and `counter` must outlive this struct.
    pub fn init(io: std.Io, counter: *std.atomic.Value(u64)) Self {
        return .{
            .io = io,
            .counter = counter,
        };
    }

    /// Exposes this clock through the ClockAndIds vtable.
    pub fn port(self: *Self) ports.ClockAndIds {
        // Keep this logic centralized so callers observe one consistent behavior path.
        return .{
            .ptr = self,
            .vtable = &.{
                .now = now,
                .nextId = nextId,
            },
        };
    }

    /// Returns the current real-clock timestamp.
    /// `monotonic_ms` is always 0 in this adapter; use the unix_ms field for
    /// wall-clock ordering. Reads the real clock, so results are not stable
    /// in deterministic test I/O mode.
    fn now(ptr: *anyopaque) ports.PortError!ports.Instant {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return .{
            .unix_ms = @intCast(@divTrunc(std.Io.Clock.now(.real, self.io).nanoseconds, std.time.ns_per_ms)),
            .monotonic_ms = 0,
        };
    }

    /// Returns a caller-owned string of the form `{prefix}{counter}`.
    /// The counter is incremented atomically with .monotonic ordering so
    /// concurrent calls never produce duplicate IDs. Caller must free with
    /// the same allocator.
    fn nextId(ptr: *anyopaque, allocator: std.mem.Allocator, request: ports.IdRequest) ports.PortError![]const u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const id = self.counter.fetchAdd(1, .monotonic);
        return std.fmt.allocPrint(allocator, "{s}{d}", .{ request.prefix, id });
    }
};
