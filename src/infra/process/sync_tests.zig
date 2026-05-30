//! Tests for sync.Mutex: pins basic lock/unlock round-trip and threaded
//! contention safety for the zero-initialized (spin) fallback path.
const std = @import("std");
const sync = @import("sync.zig");

const Mutex = sync.Mutex;

/// Shared counters used to prove the mutex protects concurrent increments.
const StressState = struct {
    mutex: Mutex = .{},
    counter: usize = 0,
};

/// Increments the shared counter enough times to exercise mutex protection.
fn stressWorker(state: *StressState) void {
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        state.mutex.lock();
        state.counter += 1;
        state.mutex.unlock();
    }
}

test "Mutex zero initializer protects a critical section" {
    var mutex: Mutex = .{};
    mutex.lock();
    mutex.unlock();
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
