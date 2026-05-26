const std = @import("std");

/// Compatibility mutex for code that needs a simple lock/unlock API.
///
/// Prefer initializing with `init(io)` so contended locks use Zig's Io-backed
/// futex path. The zero initializer is still valid for tests and single-threaded
/// use; it falls back to a small atomic spin lock.
pub const Mutex = struct {
    io: ?std.Io = null,
    io_mutex: std.Io.Mutex = .init,
    spin_mutex: std.atomic.Mutex = .unlocked,

    pub fn init(io: std.Io) Mutex {
        return .{ .io = io };
    }

    pub fn lock(self: *Mutex) void {
        if (self.io) |io| {
            self.io_mutex.lockUncancelable(io);
            return;
        }
        while (!self.spin_mutex.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Mutex) void {
        if (self.io) |io| {
            self.io_mutex.unlock(io);
            return;
        }
        self.spin_mutex.unlock();
    }
};
