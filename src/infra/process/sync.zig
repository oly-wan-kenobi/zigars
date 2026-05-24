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

test "Mutex zero initializer protects a critical section" {
    var mutex: Mutex = .{};
    mutex.lock();
    mutex.unlock();
}

const StressState = struct {
    mutex: Mutex = .{},
    counter: usize = 0,
};

fn stressWorker(state: *StressState) void {
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        state.mutex.lock();
        state.counter += 1;
        state.mutex.unlock();
    }
}

test "Mutex zero initializer survives threaded contention" {
    var state: StressState = .{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, stressWorker, .{&state});
    }
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(usize, 8000), state.counter);
}
